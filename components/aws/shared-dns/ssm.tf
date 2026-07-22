# Publish the Profile id and RAM share ARN to SSM so consumers that resolve cross-component
# values through SSM (the fleet-vend / cluster-bootstrap path) can read them without a
# terragrunt dependency edge, matching how shared-network publishes its VPC id and share ARN.
# The terragrunt dependency graph is the primary path for the static live tree; SSM covers the
# vend path that runs outside it.

resource "aws_ssm_parameter" "profile_id" {
  name  = "/platform/${var.environment}/shared-dns/profile-id"
  type  = "String"
  value = aws_route53profiles_profile.this.id
  tags  = local.tags
}

resource "aws_ssm_parameter" "ram_share_arn" {
  count = local.ram_enabled ? 1 : 0

  name  = "/platform/${var.environment}/shared-dns/ram-share-arn"
  type  = "String"
  value = aws_ram_resource_share.profile[0].arn
  tags  = local.tags
}
