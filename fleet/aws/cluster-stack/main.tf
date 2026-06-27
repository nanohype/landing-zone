# The cluster stack: network -> cluster, wired explicitly. This is the tofu-native
# equivalent of the terragrunt dependency chain (live/_envcommon/aws/cluster.hcl
# feeds the network's vpc_id + subnets into the cluster). A provider-opentofu
# Workspace runs this root to vend one cluster; outputs.tf returns what the
# Cluster claim's status needs. Adding cluster-bootstrap + agent-iam to the chain
# is the next step (they pull k8s/helm providers, so they land in a sibling root).

data "aws_partition" "current" {}

# Captures the vend time once and persists it in state — so Expiry is stable
# across re-applies (a raw timestamp() would drift every plan). Only created for
# ephemeral spokes (ttl_days > 0); persistent spokes need no expiry.
resource "time_static" "vend" {
  count = var.ttl_days > 0 ? 1 : 0
}

locals {
  # resource-tagging lifecycle/expiry. Ephemeral spokes carry Expiry = vend date
  # + ttl_days (YYYY-MM-DD); the hub reaper deletes the Cluster CR past it. These
  # merge into the modules' var.tags (provider default_tags can't reference a
  # resource like time_static; module inputs can).
  lifecycle_tags = var.ttl_days > 0 ? {
    Lifecycle = "ephemeral"
    Expiry    = formatdate("YYYY-MM-DD", timeadd(time_static.vend[0].rfc3339, "${var.ttl_days * 24}h"))
  } : { Lifecycle = "persistent" }

  # Per-cluster discovery key. The break-glass unwedge teardown targets exactly
  # this cluster's resources by matching BOTH ProvisionedBy=eks-fleet (provider
  # default_tags) AND this Cluster tag — so a teardown can never reach into a
  # sibling spoke in the same account. Mirrors the EKS cluster's own name
  # (the component prefixes cluster_name with the environment).
  spoke_tags = merge(var.tags, local.lifecycle_tags, {
    Cluster = "${var.environment}-${var.cluster_name}"
  })

  # Cross-account bootstrap auth: grant the hub role cluster-admin on the spoke via
  # an EKS access entry. The bootstrap Workspace mints its k8s token with ambient
  # creds (the hub IRSA) — it can't assume the vend role through `aws eks get-token`
  # because the fleet-vend trust requires a fixed external_id get-token can't present.
  # So the spoke must trust the hub role directly. Empty (same-account): the creator
  # (the hub itself) is already admin via enable_cluster_creator_admin_permissions.
  bootstrap_access_entries = var.bootstrap_access_role_arn == "" ? {} : {
    hub-bootstrap = {
      principal_arn = var.bootstrap_access_role_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # portal's per-account spoke role gets an access entry so portal can reach the
  # cluster API with the same role it uses for eks:DescribeCluster — mint EKS
  # tokens + watch tenants. It maps the role to the "portal-reader" Kubernetes
  # GROUP (no AWS managed access policy): the eks-gitops catalog binds that group
  # to a narrow portal-reader ClusterRole (read the platform.nanohype.dev
  # tenant/platform CRs + nodes — no Secrets, unlike the managed view policies,
  # which either miss CRDs (View) or expose Secrets (AdminView)). The control-plane
  # badge (eks:DescribeCluster) needs no entry — it's the AWS API. Empty = portal
  # not wired for this cluster.
  portal_access_entries = var.portal_access_role_arn == "" ? {} : {
    portal-read = {
      principal_arn     = var.portal_access_role_arn
      kubernetes_groups = ["portal-reader"]
    }
  }
}

module "network" {
  source = "../../../components/aws/network"

  environment                   = var.environment
  region                        = var.region
  cluster_name                  = var.cluster_name
  vpc_cidr                      = var.vpc_cidr
  max_azs                       = var.max_azs
  nat_gateways                  = var.nat_gateways
  team                          = var.team
  tags                          = local.spoke_tags
  enable_eks_interface_endpoint = var.enable_eks_interface_endpoint
}

module "cluster" {
  source = "../../../components/aws/cluster"

  environment     = var.environment
  region          = var.region
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  public_subnet_ids  = module.network.public_subnet_ids

  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  system_node_instance_types = var.system_node_instance_types
  system_node_min_size       = var.system_node_min_size
  system_node_max_size       = var.system_node_max_size
  system_node_desired_size   = var.system_node_desired_size
  system_node_disk_size      = var.system_node_disk_size

  cluster_iam_role_path            = var.cluster_iam_role_path
  cluster_permissions_boundary_arn = var.cluster_permissions_boundary_arn

  access_entries = merge(local.bootstrap_access_entries, local.portal_access_entries)

  team = var.team
  tags = local.spoke_tags
}
