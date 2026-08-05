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

  # What the EBS CSI driver stamps on every volume it provisions from a PVC.
  #
  # Such a volume is not in terraform state and carries only what the driver
  # puts on it, so without this it reaches EC2 with no cluster tag at all — and
  # the teardown sweep, which filters on kubernetes.io/cluster/<name>, finds
  # none, reports no orphans, and leaves every one of them billing after the
  # cluster is gone. Nothing fails at any point.
  #
  # `owned`, not `shared`: these volumes belong to exactly this cluster and are
  # safe to delete with it, which is the claim the sweep acts on. Subnets carry
  # `shared` (subnet_tags.tf) because a subnet legitimately outlives a cluster.
  #
  # Hoisted out of the addon's configuration_values so a test can assert it. The
  # module's cluster_addons OUTPUT is unknown at plan time, so an assertion
  # reading it passes whether or not the input is set — which is exactly what the
  # first draft of that test did.
  ebs_csi_volume_tags = merge(local.tags, {
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
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

