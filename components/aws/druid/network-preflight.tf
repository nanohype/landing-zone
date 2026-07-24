# Consumer-side network preflight. The network component already guarantees its output
# object is internally consistent and that adopted subnets reside in the VPC (adopt.tf), so
# a druid that consumes network.outputs.network whole cannot be handed a disagreeing triple.
# These checks are the belt to that suspenders: they run at plan against whatever this
# component was actually handed, so a hand-wired foreign subnet or an out-of-VPC cluster
# security group fails here — naming the offender — rather than at apply against the RDS/MSK
# API.
#
# The data-source checks are gated on adopt mode, mirroring network/adopt.tf: in create mode
# the subnets and the cluster SG are in this account's own VPC by construction (the cluster
# and the VPC are built together), and gating keeps credential-less CI — which runs create
# mode against dependency mocks — from trying to read subnet-1 / sg-mock.
#
# Constraint deliberately NOT expressed as a resource: neither druid nor pipeline may mint a
# VPC endpoint. aws_vpc_endpoint is an owner-plane resource — a participant in a shared VPC
# cannot create one — and it appears only under network / shared-network / egress-network. If
# a future edit adds one here, that is the wrong layer: the endpoint belongs to the VPC owner.

locals {
  adopt_mode = var.network.ownership_mode == "adopt"
}

# Every private subnet handed to druid must reside in the VPC it was told to use. In adopt
# mode those subnets belong to another account's shared VPC, so this is the participant-side
# proof they were wired correctly; the postcondition names the offending subnet. The data
# source exists solely for that postcondition — it returns no value the config reads, so the
# unused-declaration rule can't see its purpose.
# tflint-ignore: terraform_unused_declarations
data "aws_subnet" "placement" {
  for_each = local.adopt_mode ? toset(var.network.private_subnet_ids) : toset([])
  id       = each.value

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.network.vpc_id
      error_message = "private subnet ${each.key} is in VPC ${self.vpc_id}, not network.vpc_id (${var.network.vpc_id}). Every subnet druid places Aurora and MSK into must reside in the VPC being adopted."
    }
  }
}

# The EKS cluster security group druid references by membership in its Aurora/MSK ingress
# rules must live in the same VPC. A bare security-group-id reference resolves within one VPC;
# a cluster SG from a different VPC would attach a rule that silently never matches. (A
# same-account reference is what druid makes today — participant-created SGs are participant-
# owned — so this asserts the placement that keeps the bare-id form valid.) Postcondition-only,
# like data.aws_subnet.placement above.
# tflint-ignore: terraform_unused_declarations
data "aws_security_group" "cluster" {
  count = local.adopt_mode ? 1 : 0
  id    = var.cluster_sg_id

  lifecycle {
    postcondition {
      condition     = self.vpc_id == var.network.vpc_id
      error_message = "cluster_sg_id ${var.cluster_sg_id} is in VPC ${self.vpc_id}, not network.vpc_id (${var.network.vpc_id}). The cluster security group druid grants ingress from must reside in the same VPC as its Aurora/MSK security groups."
    }
  }
}

# AZ coverage is druid's own requirement, not a network fact: an Aurora DB subnet group needs
# subnets in at least two Availability Zones, and MSK Serverless spreads across them. Assert
# it against the object's AZ list (runs in both modes — it reads the object, no AWS call).
resource "terraform_data" "az_coverage" {
  lifecycle {
    precondition {
      condition     = length(distinct(var.network.private_subnet_azs)) >= 2
      error_message = "network.private_subnet_azs spans ${length(distinct(var.network.private_subnet_azs))} availability zone(s); druid needs at least 2 — an Aurora DB subnet group requires two AZs. Provide private subnets across at least two zones."
    }
  }
}
