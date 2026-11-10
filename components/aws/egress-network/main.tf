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

# Two selection paths, one data source. By default the subnets take the first max_azs zones
# the region returns, by name, as they always have. The zone-name filter matches every zone
# in var.region, so the default result set (and every existing VPC's zones) is unchanged; it
# is what closes the lookup to this region for CKV_AWS_394. Setting availability_zone_ids
# opts into the zone-ID path: a second filter narrows the set to those IDs, and subnets are
# built in the allowlist's order. An ID names the same physical zone in every account, so
# that is the path that lines owner and workload VPCs up across accounts. The postcondition
# fails the plan when the result cannot supply max_azs zones (or a pinned ID is missing),
# instead of letting a shorter list reach the subnet carving.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-name"
    values = ["${var.region}*"]
  }

  dynamic "filter" {
    for_each = local.pin_zone_ids ? [1] : []
    content {
      name   = "zone-id"
      values = local.pinned_zone_ids
    }
  }

  lifecycle {
    postcondition {
      condition     = length(self.names) >= var.max_azs && alltrue([for id in local.pinned_zone_ids : contains(self.zone_ids, id)])
      error_message = "the availability zones available in ${var.region} (${join(", ", self.zone_ids)}) cannot supply max_azs = ${var.max_azs}${local.pin_zone_ids ? " from availability_zone_ids (${join(", ", local.pinned_zone_ids)})" : ""}. Lower max_azs or set availability_zone_ids to zone IDs this account offers (aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneId')."
    }
  }
}

locals {
  # Zone-ID pinning is opt-in. Unset, pinned_zone_ids is empty and the name path below runs.
  pin_zone_ids    = length(var.availability_zone_ids) > 0
  pinned_zone_ids = local.pin_zone_ids ? slice(var.availability_zone_ids, 0, var.max_azs) : []

  # Pinned: this account's names for the pinned IDs, in the allowlist's order (names and
  # zone_ids are parallel lists, so zipping them maps ID to name). Unpinned: the first
  # max_azs names the region returns — the selection every existing VPC was built with.
  zone_name_by_id = zipmap(data.aws_availability_zones.available.zone_ids, data.aws_availability_zones.available.names)
  azs             = local.pin_zone_ids ? [for id in local.pinned_zone_ids : local.zone_name_by_id[id]] : slice(data.aws_availability_zones.available.names, 0, var.max_azs)

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
  version = "~> 6.0"

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
