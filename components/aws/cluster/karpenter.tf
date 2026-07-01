################################################################################
# Karpenter AWS Infrastructure
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # Cross-account fleet-vend gating: the controller + node roles land under
  # var.cluster_iam_role_path (role/eks-fleet/*) and carry the vend/hub boundary
  # (the fleet roles' CreateRole gate rejects unbounded roles). NOTE the
  # asymmetric upstream names (verified against the resolved submodule): the
  # CONTROLLER boundary input is iam_role_permissions_boundary_arn (with _arn),
  # the NODE is node_iam_role_permissions_boundary (no _arn). Path + boundary
  # default "/" + empty = outside the fleet gate.
  iam_role_path                      = var.cluster_iam_role_path
  iam_role_permissions_boundary_arn  = local.cluster_permissions_boundary
  node_iam_role_path                 = var.cluster_iam_role_path
  node_iam_role_permissions_boundary = local.cluster_permissions_boundary

  # The node role name is a cross-repo contract: eks-gitops karpenter-resources
  # pins the EC2NodeClass spec.role to "${cluster_name}-karpenter-node" (its
  # convention across dev/staging/production). The module's default name
  # (Karpenter-<cluster>-<random>) is unpredictable and unreferenceable, so the
  # EC2NodeClass and the controller's auto-scoped PassRole would point at
  # different roles and Karpenter could never launch a node. Pin to the convention.
  node_iam_role_name            = "${module.eks.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false

  # The generated controller policy exceeds the 6144-char limit on standard
  # customer-managed IAM policies; the module's documented workaround is to
  # attach it inline (10240-char limit) instead.
  enable_inline_policy = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}
