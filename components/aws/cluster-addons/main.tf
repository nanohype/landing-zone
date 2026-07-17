data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  # Key on the full cluster name (<environment>-<clusterName>), not the environment.
  # The environment alone does NOT distinguish two clusters co-located in one account
  # and environment — that's what the cluster name's unique base is for. Every
  # cluster-scoped name (IRSA roles, buckets) rides the cluster identity so siblings
  # never collide.
  irsa_role_prefix = var.cluster_name
  # Account- and region-qualified on top of the cluster name, because S3 bucket names
  # are GLOBALLY unique across every AWS account on earth — not per-account. A bare
  # "<cluster>-loki" is a name someone else already owns, so a fresh install of this
  # platform failed on:
  #
  #   Error: creating S3 Bucket: BucketAlreadyExists:
  #     The requested bucket name is not available. The bucket namespace is shared
  #     by all users of the system.
  #
  # Nothing about that is recoverable by retrying: the name will never be available.
  # It bit velero, loki, tempo and argo-workflows simultaneously, and it would bite
  # EVERY new install. The name must therefore carry everything that makes this bucket
  # distinct:
  #
  #   cluster_name  <environment>-<clusterName> — distinguishes co-located siblings.
  #   account_id    the bucket namespace is global; the account id makes the name
  #                 unique to this account, fixing the BucketAlreadyExists above.
  #   region        the account-qualified name STILL collides with itself: the same
  #                 account deploying one environment into us-west-2 and us-east-1
  #                 produces the identical name twice. Global namespace, regional
  #                 deployments.
  #
  # Each bucket below asserts the assembled name stays inside S3's 63-char limit at
  # PLAN time rather than discovering an overflow mid-apply.
  bucket_prefix = "${var.cluster_name}-${local.account_id}-${var.region}"

  tags = merge(var.tags, {
    Component = "cluster-addons"
    Team      = var.team
  })
}
