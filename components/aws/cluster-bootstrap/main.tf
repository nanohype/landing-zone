data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# The eks-agent-platform eval-runtime component writes the eval-runner role ARN
# and reports bucket to SSM; cluster-bootstrap republishes them as cluster-Secret
# annotations for the operator ApplicationSet. Gated on enable_eval_runtime so a
# cluster without eval-runtime applied doesn't fail the parameter read. The
# eval-runner role itself is bound by an EKS Pod Identity association, so only
# the reports bucket needs republishing here.
data "aws_ssm_parameter" "eval_reports_bucket" {
  count = var.enable_eval_runtime ? 1 : 0
  name  = "/eks-agent-platform/${var.environment}/eval-runtime/eval_reports_bucket"
}

# The managed-monitoring component writes the Amazon Managed Grafana workspace
# URL to SSM; cluster-bootstrap stamps it onto the cluster Secret so the
# dashboards ApplicationSet can inject it into the Grafana CR (whose url field
# the grafana-operator can't template from a Secret). Gated on
# enable_managed_monitoring so a cluster without managed-monitoring applied
# doesn't fail the parameter read.
data "aws_ssm_parameter" "grafana_url" {
  count = var.enable_managed_monitoring ? 1 : 0
  name  = "/eks-agent-platform/${var.environment}/managed-monitoring/grafana_url"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# This component manages no taggable AWS resources — it only configures the
# kubernetes/helm/github providers to bootstrap Cilium + ArgoCD on the cluster.
# So it carries no tag/label set (the resource-tagging standard applies to
# components that create cloud resources; there are none here).

################################################################################
# Kubernetes & Helm Provider Config
################################################################################

# The k8s/helm/kubectl providers authenticate with a short-lived EKS token minted
# by the AWS SDK (data.aws_eks_cluster_auth), NOT the `aws eks get-token` exec
# plugin. The exec plugin requires the `aws` CLI on PATH, which the provider-opentofu
# pod that runs this root during a fleet vend does not have (the terragrunt path
# does; the pod does not). The data-source token inherits this root's AWS identity
# — including the cross-account assume_role — so same- and cross-account vends both
# reach the spoke API. provider-opentofu re-reads the data source each reconcile,
# keeping the 15-minute token fresh across the bootstrap apply loop.
data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
  load_config_file       = false
  token                  = data.aws_eks_cluster_auth.this.token
}

################################################################################
# GitHub Provider Config
#
# Used only when tenants_repo_url is set, to register ArgoCD's read-only deploy
# key on the tenants repo. owner is parsed from that URL; the token comes from
# the GITHUB_TOKEN environment variable. When tenants_repo_url is empty, owner
# is "" and no github resources are created, so the provider is never called.
################################################################################

provider "github" {
  owner = local.tenants_repo_owner
}
