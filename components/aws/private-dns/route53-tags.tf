################################################################################
# Route 53 hosted zone tags
#
# Route 53 sets a hosted zone's tags through ChangeTagsForResource, which accepts at most
# 10 tags per call, and the provider sends the zone's whole tag set, default_tags
# included, in that one call. The root default_tags carry 11 keys on their own, so a
# zone created through the default provider is refused before any component tag is
# counted.
#
# Hosted zones therefore use a provider configuration with no default_tags and carry an
# explicit set: the default tags the org-compliance required-tags rule and cost
# allocation read, plus the component's own tags. Repository, Compliance, Lifecycle and
# Revision stay off. Revision changes on every commit, so on a zone it would only rewrite
# the tag set on every apply. The allowlist means a default tag added at the root later
# does not push a zone back over the limit.
################################################################################

provider "aws" {
  alias  = "route53"
  region = var.region
}

data "aws_default_tags" "this" {}

locals {
  route53_tag_limit = 10

  route53_default_tag_keys = [
    "Environment",
    "ManagedBy",
    "Project",
    "CostCenter",
    "BusinessUnit",
    "DataClassification",
    "Owner",
  ]

  route53_tags = merge(
    { for k, v in data.aws_default_tags.this.tags : k => v if contains(local.route53_default_tag_keys, k) },
    local.tags,
  )
}
