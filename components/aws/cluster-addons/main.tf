data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  partition        = data.aws_partition.current.partition
  irsa_role_prefix = "${var.environment}-eks"
  bucket_prefix    = "${var.environment}-eks-${local.account_id}"

  tags = merge(var.tags, {
    Component = "cluster-addons"
    Team      = var.team
  })
}
