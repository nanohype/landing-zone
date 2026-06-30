# Everything that runs AFTER the cluster is Ready, in one k8s/helm-capable root:
#   agent-iam         — the operator IRSA role + tenant boundary/baseline (AWS),
#                       keyed on the cluster's OIDC provider/issuer
#   cluster-bootstrap — Cilium + ArgoCD + the in-cluster ArgoCD Secret (k8s/helm),
#                       which makes the spoke self-reconcile the eks-gitops catalog
#                       (spoke-local ArgoCD)
#
# The eks-fleet Cluster composition runs this as a second Workspace, feeding the
# cluster identity from the first (cluster-stack) Workspace's status. This is the
# tofu-native equivalent of the env-tree chain (agent-iam + cluster-bootstrap both
# depend on the cluster's OIDC outputs).

module "agent_iam" {
  source = "../../../components/aws/agent-iam"

  environment       = var.environment
  region            = var.region
  oidc_provider_arn = var.oidc_provider_arn
  oidc_issuer       = var.oidc_issuer
  team              = var.team
  tags              = var.tags
}

module "cluster_bootstrap" {
  source = "../../../components/aws/cluster-bootstrap"

  environment                        = var.environment
  region                             = var.region
  cluster_name                       = var.cluster_name
  cluster_endpoint                   = var.cluster_endpoint
  cluster_certificate_authority_data = var.cluster_certificate_authority_data
  vpc_id                             = var.vpc_id

  enable_agent_platform = var.enable_agent_platform
  tenants_repo_url      = var.tenants_repo_url
  gitops_repo_url       = var.gitops_repo_url
  gitops_repo_branch    = var.gitops_repo_branch

  # No depends_on: this is a legacy module (it declares its own k8s/helm providers),
  # which tofu forbids depends_on/count/for_each on. It's also unnecessary — the
  # bootstrap annotates the *deterministically-named* operator role rather than
  # consuming agent-iam's output, and ArgoCD installs the operator minutes after
  # apply (well after agent-iam's role, created in this same apply, exists).
}
