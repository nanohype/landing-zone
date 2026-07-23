data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  create_mode = var.network_mode == "create"
  adopt_mode  = var.network_mode == "adopt"

  ipam_enabled = local.create_mode && var.ipam_pool_id != ""

  azs = slice(data.aws_availability_zones.available.names, 0, var.max_azs)

  # AZ IDs parallel to local.azs. Names (us-west-2a) map to different physical zones per
  # account; IDs (usw2-az1) are the only cross-account-stable zone identifier, which is
  # what a cross-account subnet consumer must pin on. aws_availability_zones returns names
  # and zone_ids in the same order, so the same slice lines them up.
  az_ids = slice(data.aws_availability_zones.available.zone_ids, 0, var.max_azs)

  # Subnet blocks are carved from the literal vpc_cidr in plain create mode, or from the
  # pinned IPAM base when drawing from a pool. Under IPAM the base comes from
  # terraform_data.ipam_cidr_pin (see below) rather than the raw preview, so it stays fixed
  # across day-2 plans — the carved subnets line up with the VPC block the module allocated
  # at apply, not whatever the pool would preview next.
  subnet_base_cidr = local.ipam_enabled ? terraform_data.ipam_cidr_pin[0].output : var.vpc_cidr

  tags = merge(var.tags, {
    Component = "network"
    Team      = var.team
  })
}

################################################################################
# IPAM CIDR preview + pin (create mode, when drawing from a pool)
################################################################################

# The preview is the next CIDR the pool would allocate for this netmask. It is not a
# reservation, and it re-evaluates on every plan — so once the VPC has allocated the
# previewed block, the next plan previews the following free CIDR.
data "aws_vpc_ipam_preview_next_cidr" "this" {
  count = local.ipam_enabled ? 1 : 0

  ipam_pool_id   = var.ipam_pool_id
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
  count = local.ipam_enabled ? 1 : 0

  input = data.aws_vpc_ipam_preview_next_cidr.this[0].cidr

  lifecycle {
    ignore_changes = [input]
  }
}

################################################################################
# VPC (create mode)
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  count = local.create_mode ? 1 : 0

  name = "${var.environment}-vpc"

  # CIDR source: literal vpc_cidr, or drawn from an IPAM pool at ipam_netmask_length.
  # When drawing from IPAM, cidr must be null — the module allocates from the pool.
  cidr                = local.ipam_enabled ? null : var.vpc_cidr
  use_ipam_pool       = local.ipam_enabled
  ipv4_ipam_pool_id   = local.ipam_enabled ? var.ipam_pool_id : null
  ipv4_netmask_length = local.ipam_enabled ? var.ipam_netmask_length : null

  azs = local.azs

  public_subnets  = [for i, az in local.azs : cidrsubnet(local.subnet_base_cidr, 8, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(local.subnet_base_cidr, 8, i + 10)]

  # Centralized egress routes private traffic out through the transit gateway (see
  # tgw.tf), so there are no NAT gateways. Otherwise the module places either a single
  # shared NAT (nat_gateways = 1) or one NAT per AZ (nat_gateways = max_azs). The upstream
  # module ties NAT-gateway count to subnet count — it can build one shared NAT or one per
  # AZ, but not an arbitrary in-between number — so those are the only two counts it can
  # honor. nat_gateways' own validation rejects an in-between value rather than letting the
  # module silently round it up to per-AZ.
  enable_nat_gateway     = !var.centralized_egress
  single_nat_gateway     = var.nat_gateways == 1
  one_nat_gateway_per_az = var.nat_gateways == var.max_azs

  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS subnet tags
  # Cluster-ownership + Karpenter-discovery tags are per-cluster and applied by the
  # cluster component (aws_ec2_tag), not here — the VPC is shared per environment and
  # cluster-agnostic, so co-located sibling clusters each stamp their own tags.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}

################################################################################
# VPC Endpoints (create mode)
################################################################################

# The endpoint set lives in a shared module so the VPC a cluster owns (here) and the
# VPC a cluster adopts (shared-network, the owner side) present the identical private
# endpoint set — one definition, no drift. In adopt mode the owner runs the endpoints,
# so this component builds none.
module "eks_vpc_endpoints" {
  source = "../../../modules/aws/eks-vpc-endpoints"

  count = local.create_mode && (var.enable_s3_gateway_endpoint || var.enable_interface_endpoints) ? 1 : 0

  vpc_id             = module.vpc[0].vpc_id
  private_subnet_ids = module.vpc[0].private_subnets
  route_table_ids = flatten([
    module.vpc[0].private_route_table_ids,
    module.vpc[0].public_route_table_ids,
  ])
  # The endpoint SG exists only when interface endpoints do; a gateway-only VPC passes none.
  security_group_id             = var.enable_interface_endpoints ? aws_security_group.vpc_endpoints[0].id : ""
  environment                   = var.environment
  enable_s3_gateway_endpoint    = var.enable_s3_gateway_endpoint
  enable_interface_endpoints    = var.enable_interface_endpoints
  enable_eks_interface_endpoint = var.enable_eks_interface_endpoint
  tags                          = local.tags
}

resource "aws_security_group" "vpc_endpoints" {
  count = local.create_mode && var.enable_interface_endpoints ? 1 : 0

  name_prefix = "${var.environment}-vpc-endpoints-"
  description = "Security group for VPC endpoints"
  vpc_id      = module.vpc[0].vpc_id

  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    # The VPC's CIDR: the literal vpc_cidr, or the pinned IPAM base the VPC is allocated
    # from (terraform_data.ipam_cidr_pin). Either way it's the same block the subnets are
    # carved from, so the endpoint SG admits exactly the VPC's own address range — not the
    # module's computed vpc_cidr_block, which is unknown until apply under IPAM.
    cidr_blocks = [local.subnet_base_cidr]
    description = "HTTPS from VPC"
  }

  tags = merge(local.tags, {
    Name = "${var.environment}-vpc-endpoints"
  })

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# VPC Flow Logs (create mode)
################################################################################

module "vpc_flow_logs" {
  source = "../../../modules/aws/vpc-flow-logs"

  count = local.create_mode && var.enable_flow_logs ? 1 : 0

  vpc_id         = module.vpc[0].vpc_id
  log_group_name = "/aws/vpc-flow-logs/${var.environment}"
  role_name      = "${var.environment}-vpc-flow-logs"
  tags           = local.tags
}
