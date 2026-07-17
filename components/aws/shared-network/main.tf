# shared-network — the owner side of the cross-account adopt topology.
#
# A central network-owner account runs this component to build one shared VPC per
# environment: it draws an IPAM-allocated CIDR, builds the full private endpoint set (via
# the same module the create-mode `network` component uses), runs egress (local NAT or a
# transit gateway to a central egress hub), stamps the ELB role tags, and RAM-shares its
# subnets to one or more workload accounts. Each workload account then runs `network` in
# adopt mode against these subnet IDs and a `cluster` with stamp_subnet_tags = false.
#
# The seam this closes: a participant account cannot tag, endpoint, or egress a VPC it does
# not own. Everything a participant cannot do for itself, the owner does here — which is why
# the owner-side contract (checks.tf + README.md) is load-bearing: the participant's adopt
# preflight can observe the S3 gateway route and default egress from its side, but it cannot
# DescribeVpcEndpoints on foreign interface endpoints, so endpoint completeness rides this
# component's own contract.

data "aws_availability_zones" "available" {
  state = "available"
}

# The org IPAM env sub-pool, discovered by the tag org-networking stamps on it
# (org-ipam-<environment>). Skipped when ipam_pool_id is pinned explicitly. A pool shared in
# over RAM from the management account is visible to this account's IPAM and discoverable
# here. one() asserts the tag resolves to exactly one pool — a missing or ambiguous pool
# fails the plan with a clear message rather than silently picking the wrong CIDR space.
data "aws_vpc_ipam_pools" "env" {
  count = var.ipam_pool_id == "" ? 1 : 0

  filter {
    name   = "tag:Name"
    values = ["org-ipam-${var.environment}"]
  }
}

locals {
  ipam_pool_id = var.ipam_pool_id != "" ? var.ipam_pool_id : one(data.aws_vpc_ipam_pools.env[0].ipam_pools).id

  azs = slice(data.aws_availability_zones.available.names, 0, var.max_azs)

  # AZ IDs parallel to local.azs. Names (us-west-2a) map to different physical zones per
  # account; IDs (usw2-az1) are the only cross-account-stable zone identifier — which is
  # exactly what a cross-account subnet consumer must pin on. aws_availability_zones returns
  # names and zone_ids in the same order, so the same slice lines them up. Subnets are built
  # one-per-AZ across local.azs in order, so subnet i sits in az_ids[i].
  az_ids = slice(data.aws_availability_zones.available.zone_ids, 0, var.max_azs)

  # The subnet-carving base is the pinned IPAM CIDR, never the raw preview. An IPAM-drawn
  # VPC CIDR is unknown at plan, so subnets can't be carved off the VPC's computed
  # cidr_block. terraform_data.ipam_cidr_pin freezes the previewed block in state at first
  # apply so the base stays fixed across day-2 plans — the carved subnets line up with the
  # block the module actually allocated, not whatever the pool would preview next.
  subnet_base_cidr = terraform_data.ipam_cidr_pin.output

  tags = merge(var.tags, {
    Component = "shared-network"
    Team      = var.team
  })
}

################################################################################
# IPAM CIDR preview + pin
################################################################################

# The preview is the next CIDR the pool would allocate for this netmask. It is not a
# reservation, and it re-evaluates on every plan — so once the VPC has allocated the
# previewed block, the next plan previews the following free CIDR.
data "aws_vpc_ipam_preview_next_cidr" "this" {
  ipam_pool_id   = local.ipam_pool_id
  netmask_length = var.ipam_netmask_length
}

# Pin the preview in state so the subnet-carving base never moves after the first apply.
# Carving straight off the data source would shift every subnet to a destructive
# replacement on the next plan (the new CIDRs don't even fit the VPC's already-allocated
# block, so the replacement can't apply — terraform-aws-modules/vpc#980, and this repo's
# scheduled drift detection would trip on it immediately). ignore_changes freezes input at
# the first applied value, so output — the carving base — stays put regardless of what the
# preview returns on later plans. A single-writer IaC flow is the assumed model, matching
# the org's per-account, per-environment VPC ownership.
resource "terraform_data" "ipam_cidr_pin" {
  input = data.aws_vpc_ipam_preview_next_cidr.this.cidr

  lifecycle {
    ignore_changes = [input]
  }
}

################################################################################
# Shared VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.environment}-shared-vpc"

  # CIDR is always drawn from the org IPAM pool: a shared VPC that adopting accounts and
  # (optionally) a transit gateway route into must hold a non-overlapping, IPAM-governed
  # prefix. cidr must be null when the module allocates from a pool.
  cidr                = null
  use_ipam_pool       = true
  ipv4_ipam_pool_id   = local.ipam_pool_id
  ipv4_netmask_length = var.ipam_netmask_length

  azs = local.azs

  public_subnets  = [for i, az in local.azs : cidrsubnet(local.subnet_base_cidr, 8, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(local.subnet_base_cidr, 8, i + 10)]
  intra_subnets   = [for i, az in local.azs : cidrsubnet(local.subnet_base_cidr, 8, i + 20)]

  # Centralized egress routes private traffic out through the transit gateway (see tgw.tf),
  # so there are no NAT gateways. Otherwise NAT count follows nat_gateways.
  enable_nat_gateway     = !var.centralized_egress
  single_nat_gateway     = var.nat_gateways == 1
  one_nat_gateway_per_az = var.nat_gateways >= var.max_azs

  enable_dns_hostnames = true
  enable_dns_support   = true

  # ELB role tags only — the cluster-agnostic convention. See subnet_tags.tf for why there
  # is deliberately NO kubernetes.io/cluster/<cluster> ownership tag here.
  public_subnet_tags  = local.public_subnet_role_tags
  private_subnet_tags = local.private_subnet_role_tags

  tags = local.tags
}

################################################################################
# VPC Flow Logs (owner logs the shared VPC on behalf of every adopting account)
################################################################################

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  iam_role_arn    = aws_iam_role.flow_logs[0].arn
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn
  traffic_type    = "ALL"
  vpc_id          = module.vpc.vpc_id

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc-flow-logs/${var.environment}-shared"
  retention_in_days = 30

  tags = local.tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.environment}-shared-net-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.environment}-shared-net-flow-logs"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}
