# The AWS provider terragrunt normally generates from root.hcl, made explicit so
# this directory works as a plain-tofu root (provider-terraform runs `tofu`, not
# `terragrunt`). Tags mirror root.hcl's default_tags + mark fleet-vended clusters.
#
# assume_role is the cross-account hinge: empty = use the runner's own identity
# (same-account, rung 1); set it to the workload account's vend role to provision
# into a spoke (rung 2). The hub's Crossplane SA is allowed to assume that role.
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
      role_arn = var.assume_role_arn
    }
  }
}
