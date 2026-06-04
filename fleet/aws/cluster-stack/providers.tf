# The AWS provider terragrunt normally generates from root.hcl, made explicit so
# this directory works as a plain-tofu root (provider-opentofu runs `tofu`, not
# `terragrunt`). Tags mirror root.hcl's default_tags + mark fleet-vended clusters.
#
# assume_role is the cross-account hinge: empty = use the runner's own identity
# (same-account, rung 1); set it to the workload account's vend role to provision
# into a spoke (rung 2). The hub's Crossplane SA is allowed to assume that role,
# presenting external_id (the fleet-vend trust requires sts:ExternalId).
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment   = var.environment
      ManagedBy     = "opentofu"
      Project       = "landing-zone"
      ProvisionedBy = "eks-fleet"
      Team          = var.team
    }
  }

  dynamic "assume_role" {
    for_each = var.assume_role_arn != "" ? [1] : []
    content {
      role_arn    = var.assume_role_arn
      external_id = var.external_id
    }
  }
}
