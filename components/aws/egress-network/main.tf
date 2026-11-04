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

# Zones are selected by ID from var.availability_zone_ids, never by taking the first N names
# the region returns. The zone-id filter closes the set: a zone AWS adds to the region later
# cannot enter it unasked (CKV_AWS_394), and an ID names the same physical zone in every
# account, where a name does not. The postcondition fails the plan when a pinned zone is not
# available to this account, instead of letting a shorter result reach the subnet carving.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-id"
    values = local.pinned_zone_ids
  }

  lifecycle {
    postcondition {
      condition     = alltrue([for id in local.pinned_zone_ids : contains(self.zone_ids, id)])
      error_message = "availability_zone_ids pins ${join(", ", local.pinned_zone_ids)} but this account reports only ${join(", ", self.zone_ids)} as available among them. Set availability_zone_ids to zone IDs this region offers (aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneId')."
    }
  }
}

locals {
  # The first max_azs zone IDs of the allowlist, in its order. The data source filters on
  # these, so it returns exactly the zones the subnets are built in.
  pinned_zone_ids = slice(var.availability_zone_ids, 0, var.max_azs)

  # Zone names in the order of local.pinned_zone_ids. The data source returns names and
  # zone_ids as parallel lists, so zipping them maps each pinned ID to this account's name.
  zone_name_by_id = zipmap(data.aws_availability_zones.available.zone_ids, data.aws_availability_zones.available.names)
  azs             = [for id in local.pinned_zone_ids : local.zone_name_by_id[id]]

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

module "vpc_flow_logs" {
  source = "../../../modules/aws/vpc-flow-logs"

  count = var.enable_flow_logs ? 1 : 0

  vpc_id         = module.vpc.vpc_id
  log_group_name = "/aws/vpc-flow-logs/${var.environment}-egress"
  role_name      = "${var.environment}-egress-flow-logs"
  tags           = local.tags
}
