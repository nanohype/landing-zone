################################################################################
# EKS Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  endpoint_public_access       = var.cluster_endpoint_public_access
  endpoint_public_access_cidrs = length(var.cluster_endpoint_public_access_cidrs) > 0 ? var.cluster_endpoint_public_access_cidrs : ["0.0.0.0/0"]
  endpoint_private_access      = true

  authentication_mode = "API"
  # Grant the principal that applies this component cluster-admin via an
  # access entry. Without it an API-auth cluster has no human-reachable
  # admin (only the EKS service + node roles are mapped), so nothing can
  # bootstrap ArgoCD/addons. Maps the applier dynamically — no hardcoded ARN.
  enable_cluster_creator_admin_permissions = true

  create_kms_key = false

  encryption_config = {
    provider_key_arn = module.kms.key_arn
    resources        = ["secrets"]
  }

  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # EKS managed add-ons (AWS-managed lifecycle)
  # vpc-cni must be installed before node groups via before_compute
  addons = {
    vpc-cni = {
      most_recent                 = true
      before_compute              = true
      resolve_conflicts_on_create = "OVERWRITE"
      configuration_values = jsonencode({
        env = { ENABLE_PREFIX_DELEGATION = "true" }
      })
    }
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
    kube-proxy = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn
    }
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }
  }

  # System node group — runs critical platform addons
  eks_managed_node_groups = {
    system = {
      name           = "${var.environment}-system"
      instance_types = var.system_node_instance_types
      ami_type       = "BOTTLEROCKET_ARM_64"
      min_size       = var.system_node_min_size
      max_size       = var.system_node_max_size
      desired_size   = var.system_node_desired_size
      disk_size      = var.system_node_disk_size
      capacity_type  = "ON_DEMAND"

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }

      labels = {
        "node-role" = "system"
      }
    }
  }

  access_entries = var.access_entries

  # Allow Karpenter node role to join the cluster
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.cluster_name
  }

  tags = local.tags
}
