################################################################################
# IRSA Roles for All Platform Addons
################################################################################

locals {
  irsa_role_prefix = "${var.environment}-eks"
}

# EBS CSI Driver
module "ebs_csi_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name         = "${local.irsa_role_prefix}-ebs-csi"
  oidc_provider_arn = local.oidc_provider_arn
  oidc_issuer       = local.oidc_issuer
  namespace         = "kube-system"
  service_account   = "ebs-csi-controller-sa"

  managed_policy_arns = [
    "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]

  # cross-account fleet-vend gating: the IRSA role under the fleet path
  path                 = var.cluster_iam_role_path
  permissions_boundary = local.cluster_permissions_boundary

  tags = local.tags
}
