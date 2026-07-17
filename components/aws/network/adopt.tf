# Adopt mode: participate in a VPC this account does not own. Nothing is built —
# vpc_id / subnets / CIDR / AZs are resolved from the adopt_* inputs via read-only data
# sources, and the outputs re-export them so a consuming cluster wires against the same
# interface it uses in create mode.
#
# The data sources carry the consumer-side adopt preflight: assertions that run at plan
# and fail there, not silently at cluster-Ready. What CAN be asserted from the
# participant side is asserted hard here — subnet placement, the S3 gateway route, a
# default egress route, AZ coverage. What CANNOT: a participant cannot DescribeVpcEndpoints
# on the owner's foreign interface endpoints, so interface-endpoint completeness is not
# assertable here. That completeness rides the owner's contract (shared-network's own
# check blocks + README) plus real DNS resolution at bootstrap. The gateway route and
# subnet-placement checks below are the hard, observable-from-the-participant-side
# guarantees.

data "aws_vpc" "adopt" {
  count = local.adopt_mode ? 1 : 0
  id    = var.adopt_vpc_id
}

data "aws_subnet" "adopt_private" {
  for_each = local.adopt_mode ? toset(var.adopt_private_subnet_ids) : toset([])
  id       = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.adopt_vpc_id
      error_message = "adopt private subnet ${each.key} is in VPC ${self.vpc_id}, not adopt_vpc_id (${var.adopt_vpc_id}). Every adopted subnet must reside in the adopted VPC."
    }
  }
}

data "aws_subnet" "adopt_public" {
  for_each = local.adopt_mode ? toset(var.adopt_public_subnet_ids) : toset([])
  id       = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.adopt_vpc_id
      error_message = "adopt public subnet ${each.key} is in VPC ${self.vpc_id}, not adopt_vpc_id (${var.adopt_vpc_id}). Every adopted subnet must reside in the adopted VPC."
    }
  }
}

data "aws_route_table" "adopt_private" {
  for_each  = local.adopt_mode ? toset(var.adopt_private_subnet_ids) : toset([])
  subnet_id = each.value

  lifecycle {
    # The S3 gateway endpoint installs a prefix-list route (destination_prefix_list_id +
    # the endpoint as target) into every private route table it associates with. Its
    # presence is the participant-observable proof the owner wired the S3 gateway path —
    # without it, private-subnet image and model-artifact pulls fall to NAT/public
    # resolution: slower, and billed on NAT data processing.
    postcondition {
      condition     = anytrue([for r in self.routes : try(r.destination_prefix_list_id, "") != ""])
      error_message = "adopted private route table ${self.id} (subnet ${each.key}) has no S3 gateway prefix-list route. The network owner must associate the S3 gateway VPC endpoint with every shared private route table (see shared-network's contract)."
    }

    # A default egress route (NAT or TGW) must exist, or private-subnet nodes cannot
    # reach the EKS API endpoint or pull from public registries during bootstrap.
    postcondition {
      condition     = anytrue([for r in self.routes : try(r.cidr_block, "") == "0.0.0.0/0"])
      error_message = "adopted private route table ${self.id} (subnet ${each.key}) has no default egress route (0.0.0.0/0). The owner must provide NAT or TGW egress on every shared private route table."
    }
  }
}

# AZ coverage is a cross-subnet assertion (it needs every subnet's AZ), so it can't be a
# per-instance postcondition. terraform_data is a config-only resource; its precondition
# runs at plan and fails there when the adopted private subnets don't span max_azs zones.
resource "terraform_data" "adopt_az_coverage" {
  count = local.adopt_mode ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(distinct([for s in data.aws_subnet.adopt_private : s.availability_zone])) >= var.max_azs
      error_message = "adopted private subnets span ${length(distinct([for s in data.aws_subnet.adopt_private : s.availability_zone]))} availability zone(s) but max_azs is ${var.max_azs}. Provide adopt_private_subnet_ids across at least max_azs zones so the system node group can spread."
    }
  }
}

################################################################################
# Resolved values — identical outputs in both modes
################################################################################

locals {
  resolved_vpc_id   = local.create_mode ? module.vpc[0].vpc_id : var.adopt_vpc_id
  resolved_vpc_cidr = local.create_mode ? module.vpc[0].vpc_cidr_block : data.aws_vpc.adopt[0].cidr_block

  resolved_private_subnet_ids = local.create_mode ? module.vpc[0].private_subnets : var.adopt_private_subnet_ids
  resolved_public_subnet_ids  = local.create_mode ? module.vpc[0].public_subnets : var.adopt_public_subnet_ids
  resolved_intra_subnet_ids   = local.create_mode ? module.vpc[0].intra_subnets : []

  # Create mode: subnets are built one-per-AZ across local.azs, in order, so the AZ list
  # is local.azs. Adopt mode: read each subnet's AZ, preserving input order.
  resolved_private_subnet_azs = local.create_mode ? local.azs : [for id in var.adopt_private_subnet_ids : data.aws_subnet.adopt_private[id].availability_zone]
  resolved_public_subnet_azs  = local.create_mode ? local.azs : [for id in var.adopt_public_subnet_ids : data.aws_subnet.adopt_public[id].availability_zone]

  resolved_private_route_table_ids = local.create_mode ? module.vpc[0].private_route_table_ids : [for id in var.adopt_private_subnet_ids : data.aws_route_table.adopt_private[id].route_table_id]
  resolved_public_route_table_ids  = local.create_mode ? module.vpc[0].public_route_table_ids : []
  resolved_natgw_ids               = local.create_mode ? module.vpc[0].natgw_ids : []
}
