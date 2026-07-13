data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  partition        = data.aws_partition.current.partition
  irsa_role_prefix = "${var.environment}-eks"
  # Account-qualified, because S3 bucket names are GLOBALLY unique across every AWS
  # account on earth — not per-account. "dev-eks-loki" is a name someone else already
  # owns, so a fresh install of this platform failed on:
  #
  #   Error: creating S3 Bucket (dev-eks-loki): BucketAlreadyExists:
  #     The requested bucket name is not available. The bucket namespace is shared
  #     by all users of the system.
  #
  # Nothing about that is recoverable by retrying: the name will never be available.
  # It bit velero, loki, tempo and argo-workflows simultaneously, and it would bite
  # EVERY new install — the only reason it went unnoticed is that the buckets were
  # created once, long ago, in an account that got there first.
  bucket_prefix = "${var.environment}-eks-${local.account_id}"

  tags = merge(var.tags, {
    Component = "cluster-addons"
    Team      = var.team
  })
}
