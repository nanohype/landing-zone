locals {
  tags = merge(var.tags, {
    Component = "shared-dns"
    Team      = var.team
  })
}

################################################################################
# Private Hosted Zones
#
# Each zone is seeded with the owner-account VPC because Route53 requires a
# same-account VPC association at creation (a private zone cannot be created
# VPC-less). Resolution across the fleet does not ride this association — it
# rides the Profile attachment below. The seed association is the creation
# requirement only.
################################################################################

resource "aws_route53_zone" "private" {
  for_each = toset(var.private_zones)

  name    = each.value
  comment = "${var.environment} private zone ${each.value} (shared via Route53 Profile)"

  vpc {
    vpc_id = var.seed_vpc_id
  }

  tags = merge(local.tags, {
    Name = each.value
  })

  # The Profile is the fleet-wide resolution path. Terraform would otherwise try to reconcile
  # away VPC associations the Profile makes on consumer VPCs (they appear as associations this
  # resource does not manage), so ignore them — the Profile owns them, not this zone resource.
  lifecycle {
    ignore_changes = [vpc]
  }
}

################################################################################
# Route53 Profile + zone attachments
#
# The Profile bundles the private zones and is shared to consumer accounts over
# RAM (ram.tf). A consumer associates the Profile with its cluster VPC and every
# attached zone resolves there — the owner adds a zone once and it propagates,
# with no per-zone-per-VPC association fan-out.
################################################################################

resource "aws_route53profiles_profile" "this" {
  name = "${var.environment}-private-dns"

  tags = merge(local.tags, {
    Name = "${var.environment}-private-dns"
  })
}

resource "aws_route53profiles_resource_association" "zone" {
  for_each = aws_route53_zone.private

  name         = "${var.environment}-${replace(each.key, ".", "-")}"
  profile_id   = aws_route53profiles_profile.this.id
  resource_arn = each.value.arn
}
