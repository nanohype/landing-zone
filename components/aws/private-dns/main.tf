locals {
  tags = merge(var.tags, {
    Component = "private-dns"
    Team      = var.team
  })
}

################################################################################
# Participant preflight
#
# Assert what IS observable from the participant side at plan: the VPC exists in
# this account and has DNS resolution enabled. A Profile association on a VPC
# with enableDnsSupport = false is inert — the private zones would never resolve
# — so catch it at plan rather than as a silent no-op after apply. What CANNOT
# be asserted here (that the Profile actually carries zones, that resolution
# works end to end) rides the owner's contract plus real DNS resolution at
# bootstrap, the same split the network adopt preflight documents.
################################################################################

data "aws_vpc" "target" {
  id = var.vpc_id

  lifecycle {
    postcondition {
      condition     = self.enable_dns_support
      error_message = "vpc ${var.vpc_id} has DNS resolution disabled (enableDnsSupport = false). A Route53 Profile association is inert without it — the private zones would never resolve. Enable DNS support on the VPC first."
    }
  }
}

################################################################################
# Profile -> VPC association
#
# The consumer side of the Route53 Profile share: associate the shared Profile
# with this cluster's VPC. Every private zone the Profile carries then resolves
# inside the VPC. This is the only cross-account DNS operation a workload account
# performs — one association, under the default read-only RAM permission, not a
# per-zone authorization/association dance.
################################################################################

resource "aws_route53profiles_association" "this" {
  name        = "${var.environment}-private-dns"
  profile_id  = var.profile_id
  resource_id = data.aws_vpc.target.id

  tags = local.tags
}
