# RAM share of the Route53 Profile to the consuming workload accounts.
#
# allow_external_principals = false keeps the share inside the AWS Organization — a consumer
# account id that is not an org member cannot be associated. Org-wide resource sharing must be
# enabled in AWS Organizations first, or a false-external share will not resolve for principals
# outside the owner's own account tree (documented in README.md, same as shared-network).
#
# Consumers get the DEFAULT (read-only) RAM permission: they can associate the shared Profile
# with their own VPCs but cannot modify it or add resources to it. That is exactly this model —
# the owner owns the zones, the consumer only consumes. The custom AssociateResourceToProfile
# permission (which would let a consumer attach its own resources to the Profile) is
# deliberately not granted.
#
# The whole share is gated on consumer_account_ids being non-empty: with no consumers there is
# nothing to share to, and the owner-side contract check (checks.tf) fails the plan to make
# that explicit rather than silently producing an orphan share.

locals {
  ram_enabled = length(var.consumer_account_ids) > 0
}

resource "aws_ram_resource_share" "profile" {
  count = local.ram_enabled ? 1 : 0

  name                      = "${var.environment}-private-dns"
  allow_external_principals = false

  tags = merge(local.tags, {
    Name = "${var.environment}-private-dns"
  })
}

resource "aws_ram_resource_association" "profile" {
  count = local.ram_enabled ? 1 : 0

  resource_arn       = aws_route53profiles_profile.this.arn
  resource_share_arn = aws_ram_resource_share.profile[0].arn
}

resource "aws_ram_principal_association" "consumer" {
  for_each = local.ram_enabled ? toset(var.consumer_account_ids) : toset([])

  principal          = each.value
  resource_share_arn = aws_ram_resource_share.profile[0].arn
}
