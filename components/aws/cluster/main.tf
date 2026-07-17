data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  cluster_name = "${var.environment}-${var.cluster_name}"
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition

  oidc_issuer = replace(module.eks.cluster_oidc_issuer_url, "https://", "")

  # "" (the unset default, same-account) → null so the role-minting modules attach
  # no boundary. Single conversion point — every module input references this local,
  # never the raw var, or IAM would get a literal empty-string boundary ARN.
  cluster_permissions_boundary = var.cluster_permissions_boundary_arn != "" ? var.cluster_permissions_boundary_arn : null

  tags = merge(var.tags, {
    Component = "cluster"
    Team      = var.team
  })
}

################################################################################
# KMS Key for EKS Secrets Encryption
################################################################################

module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.0"

  aliases     = ["eks/${local.cluster_name}"]
  description = "KMS key for EKS secrets encryption"

  key_administrators = [
    "arn:${local.partition}:iam::${local.account_id}:root"
  ]

  key_service_roles_for_autoscaling = [
    "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
  ]

  tags = local.tags
}

