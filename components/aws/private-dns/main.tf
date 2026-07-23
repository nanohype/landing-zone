locals {
  create_mode = var.dns_mode == "create"
  adopt_mode  = var.dns_mode == "adopt"

  tags = merge(var.tags, {
    Component = "private-dns"
    Team      = var.team
  })
}

################################################################################
# Preflight (both modes)
#
# Assert what IS observable at plan: the VPC exists in this account and has DNS
# resolution enabled. A private hosted zone OR a Profile association on a VPC
# with enableDnsSupport = false is inert — the private names would never resolve
# — so catch it at plan rather than as a silent no-op after apply.
################################################################################

data "aws_vpc" "target" {
  id = var.vpc_id

  lifecycle {
    postcondition {
      condition     = self.enable_dns_support
      error_message = "vpc ${var.vpc_id} has DNS resolution disabled (enableDnsSupport = false). Private DNS is inert without it — the zones would never resolve. Enable DNS support on the VPC first."
    }
  }
}

################################################################################
# create mode — own private hosted zone(s) in this account's own VPC
#
# The single-account path (maturity ladder): a startup that wants an internal
# service domain builds it here, associated with its own VPC, with no Route53
# Profile and no cross-account sharing. external-dns writes records into these.
################################################################################

resource "aws_route53_zone" "private" {
  for_each = local.create_mode ? toset(var.private_zones) : toset([])

  name    = each.value
  comment = "${var.environment} private zone ${each.value}"

  vpc {
    vpc_id = data.aws_vpc.target.id
  }

  tags = merge(local.tags, {
    Name = each.value
  })
}

################################################################################
# adopt mode — associate a shared Route53 Profile with this account's VPC
#
# The multi-account path (enterprise): the consumer side of a shared-dns owner's
# Profile. Every private zone the Profile carries resolves in this VPC after the
# association — one operation, under the default read-only RAM permission.
################################################################################

resource "aws_route53profiles_association" "this" {
  count = local.adopt_mode ? 1 : 0

  name        = "${var.environment}-private-dns"
  profile_id  = var.profile_id
  resource_id = data.aws_vpc.target.id

  tags = local.tags
}
