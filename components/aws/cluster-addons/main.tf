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
  # S3 bucket names live in ONE GLOBAL NAMESPACE — not per-account, and not per-region.
  # The name must therefore carry everything that makes this cluster distinct:
  #
  #   environment  two clusters in one account
  #   account_id   "dev-eks-loki" is a name somebody else on earth already owns. A fresh
  #                install failed on exactly that — BucketAlreadyExists, which no amount
  #                of retrying can fix, because the name is never coming back.
  #   region       the account-qualified name STILL collides with itself: the same
  #                account deploying `dev` into us-west-2 and us-east-1 produces the
  #                identical name twice. Global namespace, regional deployments.
  #
  # Worst case is 58 characters (production-eks-<12-digit-account>-ap-southeast-4-
  # argo-workflows), inside S3's 63-char limit — and each bucket below asserts that at
  # PLAN time rather than discovering it mid-apply.
  bucket_prefix = "${var.environment}-eks-${local.account_id}-${var.region}"

  tags = merge(var.tags, {
    Component = "cluster-addons"
    Team      = var.team
  })
}
