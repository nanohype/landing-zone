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
  provider = aws.route53

  name    = each.value
  comment = "${var.environment} private zone ${each.value}"

  vpc {
    vpc_id = data.aws_vpc.target.id
  }

  tags = merge(local.route53_tags, {
    Name = each.value
  })

  lifecycle {
    precondition {
      condition     = length(merge(local.route53_tags, { Name = each.value })) <= local.route53_tag_limit
      error_message = "hosted zone ${each.value} would carry ${length(merge(local.route53_tags, { Name = each.value }))} tags; Route 53 accepts at most ${local.route53_tag_limit} per ChangeTagsForResource call. Trim var.tags."
    }

    # tags_all is the set the provider sends to ChangeTagsForResource: tags plus the
    # provider's default_tags. The precondition above counts tags alone, which is the whole
    # set only while the route53 provider carries no default_tags.
    postcondition {
      condition     = length(self.tags_all) <= local.route53_tag_limit
      error_message = "hosted zone ${self.name} would be sent ${length(self.tags_all)} tags; Route 53 accepts at most ${local.route53_tag_limit} per ChangeTagsForResource call. The route53 provider in route53-tags.tf must not carry default_tags."
    }
  }
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
