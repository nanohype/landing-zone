data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# The eks-agent-platform eval-runtime component writes the eval-runner role ARN
# and reports bucket to SSM; cluster-bootstrap republishes them as cluster-Secret
# annotations for the operator ApplicationSet. Gated on enable_eval_runtime so a
# cluster without eval-runtime applied doesn't fail the parameter read.
data "aws_ssm_parameter" "eval_runner_role_arn" {
  count = var.enable_eval_runtime ? 1 : 0
  name  = "/eks-agent-platform/${var.environment}/eval-runtime/runner_role_arn"
}

data "aws_ssm_parameter" "eval_reports_bucket" {
  count = var.enable_eval_runtime ? 1 : 0
  name  = "/eks-agent-platform/${var.environment}/eval-runtime/eval_reports_bucket"
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

provider "kubernetes" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = var.cluster_endpoint
    cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
    }
  }
}

provider "kubectl" {
  host                   = var.cluster_endpoint
  cluster_ca_certificate = base64decode(var.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
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
