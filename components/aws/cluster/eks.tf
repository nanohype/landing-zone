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

  # Cross-account fleet-vend gating: the cluster IAM role + the encryption managed
  # policy land under var.cluster_iam_role_path so the vend role's CreateRole /
  # CreatePolicy (scoped to /eks-fleet/*) is satisfied. Defaults "/" = same-account.
  iam_role_path                 = var.cluster_iam_role_path
  iam_role_permissions_boundary = local.cluster_permissions_boundary
  encryption_policy_path        = var.cluster_iam_role_path

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
      # Credentials come from the ebs_csi_irsa Pod Identity association
      # (pods.eks.amazonaws.com trust) + the eks-pod-identity-agent addon, so the
      # addon takes no service_account_role_arn — that annotates the SA for
      # IRSA/web-identity, which a Pod-Identity-only role can't satisfy and the
      # controller crashloops on.
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
      capacity_type  = "ON_DEMAND"

      # `disk_size` USED TO BE SET HERE, AND DID NOTHING.
      #
      # terraform-aws-eks v21 always builds a custom launch template for a managed node
      # group, and `disk_size` is silently ignored whenever one is used. It is accepted,
      # it validates, it plans clean, and AWS never sees it — the node group reported
      # `diskSize: null` and the launch template's BlockDeviceMappings was null, so the
      # instances fell back to the AMI's own defaults.
      #
      # For BOTTLEROCKET that default is a 2 GiB OS volume (/dev/xvda) plus a **20 GiB
      # data volume** (/dev/xvdb) — and /dev/xvdb is where container images and
      # ephemeral storage live. 20 GiB does not fit this platform's image set. On a
      # fresh install the system nodes hit DiskPressure while the addons were still
      # pulling, the kubelet evicted 30 pods (the ArgoCD ApplicationSet controller
      # among them), and convergence went backwards — 40/44 Applications healthy, then
      # 38, then 37. Karpenter's nodes were fine throughout, because its EC2NodeClass
      # sizes its volumes explicitly. Only the managed group was left on the defaults.
      #
      # The knob that actually reaches AWS is block_device_mappings. Size /dev/xvdb;
      # /dev/xvda is deliberately left alone, since the Bottlerocket OS image is
      # read-only and 2 GiB is what it is designed for.
      block_device_mappings = {
        xvdb = {
          device_name = "/dev/xvdb"
          ebs = {
            volume_size           = var.system_node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # node-group role under the fleet-vend path (v21 sets these per-group, not
      # via an eks_managed_node_group_defaults var)
      iam_role_path                 = var.cluster_iam_role_path
      iam_role_permissions_boundary = local.cluster_permissions_boundary

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
