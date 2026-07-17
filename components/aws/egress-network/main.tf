# egress-network — the central-egress hub, the receiving end of centralized egress.
#
# A spoke VPC that flips centralized_egress (the create-mode `network` component, or a
# shared-network owner VPC) stops running local NAT and instead points its private default
# route (0.0.0.0/0) at the org transit gateway. Something has to terminate that traffic on
# the far side of the TGW and carry it to the internet — that is this component. It builds a
# small VPC with NAT gateways in public subnets, attaches its NAT-facing private subnets to
# the TGW, and adds a return route so NAT-translated replies find their way back to the
# originating spoke.
#
# The one resource that actually steers spoke default egress at this hub — the static
# 0.0.0.0/0 route in the TGW's route table — is NOT here. A TGW participant cannot create,
# modify, or delete the owner's transit gateway route tables (AWS blocks it), so that route
# lives in org-networking, the TGW owner. This component builds everything a participant is
# permitted to build and publishes tgw_attachment_id for the owner to target. See README.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.max_azs)

  # Subnets are carved to a fixed /28 off the dedicated egress CIDR: newbits = 28 - base.
  # Public subnets (low indices) hold the NAT gateways + internet gateway; private subnets
  # (offset by 8) hold the TGW attachment ENIs and route their default out through NAT.
  subnet_newbits  = 28 - tonumber(split("/", var.egress_vpc_cidr)[1])
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.egress_vpc_cidr, local.subnet_newbits, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(var.egress_vpc_cidr, local.subnet_newbits, i + 8)]

  tags = merge(var.tags, {
    Component = "egress-network"
    Team      = var.team
  })
}

################################################################################
# Egress VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.environment}-egress-vpc"
  cidr = var.egress_vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # NAT is the whole point of an egress hub, so it is always on. The module builds either a
  # single shared NAT (nat_gateways = 1) or one NAT per AZ (nat_gateways = max_azs); the
  # nat_gateways validation rejects any in-between value the module would silently round up.
  enable_nat_gateway     = true
  single_nat_gateway     = var.nat_gateways == 1
  one_nat_gateway_per_az = var.nat_gateways == var.max_azs

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.tags
}

################################################################################
# VPC Flow Logs (egress traffic visibility)
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

  name              = "/aws/vpc-flow-logs/${var.environment}-egress"
  retention_in_days = 30

  tags = local.tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.environment}-egress-flow-logs"

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

  name = "${var.environment}-egress-flow-logs"
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
