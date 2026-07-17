################################################################################
# IRSA Roles for All Platform Addons
################################################################################

locals {
  # Key on the full cluster name (<environment>-<clusterName>), not the environment,
  # so this cluster's addon IRSA roles don't collide with a co-located sibling in the
  # same account and environment.
  irsa_role_prefix = local.cluster_name
}

# EBS CSI Driver
module "ebs_csi_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name = "${local.irsa_role_prefix}-ebs-csi"
  # module.eks.cluster_name, not the local string: the Pod Identity association
  # this module creates must be ordered AFTER the cluster exists (like karpenter's),
  # or tofu attempts CreatePodIdentityAssociation before the cluster is up — it
  # never lands, the ebs-csi controller never gets creds, and the addon-wait
  # deadlocks. Same value, load-bearing dependency.
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"

  managed_policy_arns = [
    "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]

  # cross-account fleet-vend gating: the IRSA role under the fleet path
  path                 = var.cluster_iam_role_path
  permissions_boundary = local.cluster_permissions_boundary

  tags = local.tags
}
