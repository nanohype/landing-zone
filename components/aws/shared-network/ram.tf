# RAM share of the shared subnets to the consuming workload accounts.
#
# Private subnets are always shared (an adopting cluster places its node ENIs there); public
# subnets are shared only when share_public_subnets is set (internet-facing load balancers).
# allow_external_principals = false keeps the share inside the AWS Organization — a consumer
# account ID that is not an org member cannot be associated. Org-wide resource sharing must
# be enabled in AWS Organizations first, or a false-external share will not resolve for
# principals outside the owner's own account tree (documented in README.md).
#
# The whole share is gated on consumer_account_ids being non-empty: with no consumers there
# is nothing to share to, and the owner-side contract check (checks.tf) fails the plan to
# make that explicit rather than silently producing an orphan share.

locals {
  # Order is load-bearing: private ARNs first, then public (when shared). aws_subnet.*.arn
  # values are known only after apply, but the LIST LENGTH is known at plan (one subnet per
  # AZ per tier), so a count-indexed association plans cleanly where a for_each over the
  # unknown ARN values could not.
  shared_subnet_arns = concat(
    module.vpc.private_subnet_arns,
    var.share_public_subnets ? module.vpc.public_subnet_arns : [],
  )

  ram_enabled = length(var.consumer_account_ids) > 0
}

resource "aws_ram_resource_share" "subnets" {
  count = local.ram_enabled ? 1 : 0

  name                      = "${var.environment}-shared-subnets"
  allow_external_principals = false

  tags = merge(local.tags, {
    Name = "${var.environment}-shared-subnets"
  })
}

resource "aws_ram_resource_association" "subnet" {
  count = local.ram_enabled ? length(local.shared_subnet_arns) : 0

  resource_arn       = local.shared_subnet_arns[count.index]
  resource_share_arn = aws_ram_resource_share.subnets[0].arn
}

resource "aws_ram_principal_association" "consumer" {
  for_each = local.ram_enabled ? toset(var.consumer_account_ids) : toset([])

  principal          = each.value
  resource_share_arn = aws_ram_resource_share.subnets[0].arn
}
