################################################################################
# Karpenter AWS Infrastructure
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  cluster_name = module.eks.cluster_name

  # The generated controller policy exceeds the 6144-char limit on standard
  # customer-managed IAM policies; the module's documented workaround is to
  # attach it inline (10240-char limit) instead.
  enable_inline_policy = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}
