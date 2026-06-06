# The cluster stack: network -> cluster, wired explicitly. This is the tofu-native
# equivalent of the terragrunt dependency chain (live/_envcommon/aws/cluster.hcl
# feeds the network's vpc_id + subnets into the cluster). A provider-terraform
# Workspace runs this root to vend one cluster; outputs.tf returns what the
# Cluster claim's status needs. Adding cluster-bootstrap + agent-iam to the chain
# is the next step (they pull k8s/helm providers, so they land in a sibling root).

data "aws_partition" "current" {}

locals {
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
  tags                          = var.tags
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

  access_entries = local.bootstrap_access_entries

  team = var.team
  tags = var.tags
}
