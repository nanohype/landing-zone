# Unit tests for cluster-bootstrap's ArgoCD cluster-registration Secret — the
# object whose labels and annotations drive every eks-gitops ApplicationSet
# generator. This suite pins the managed-monitoring gating: opencost is split into
# its own ApplicationSet that selects on a dedicated `monitoring/managed` label
# (not the generic eks-agent-platform/enabled), because opencost queries Amazon
# Managed Prometheus and can only render on a cluster that also carries the
# monitoring/amp-workspace-id annotation. The label and that annotation share one
# gate — var.enable_managed_monitoring — so a cluster the opencost generator
# selects always has the annotation opencost reads. Drop the label and opencost
# never targets a managed-monitoring cluster; stamp it without the gate and
# opencost targets clusters whose annotation is absent and generates an
# Application that can never render. Both are silent regressions this suite bites.
#
# Runs at command = plan against mocked aws/kubernetes/helm/kubectl providers. The
# Secret's metadata is a plain merge()/jsonencode of variables and mocked SSM
# reads, so the labels and annotations render for real at plan time. The default
# tenants_repo_url = "" keeps the tls/github deploy-key resources at count 0, so
# those providers are never configured.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDTEST"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }
  mock_data "aws_eks_cluster_auth" {
    defaults = {
      token = "mock-eks-token"
    }
  }
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "mock-ssm-value"
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}

variables {
  environment                        = "staging"
  region                             = "us-west-2"
  cluster_name                       = "staging-platform"
  cluster_endpoint                   = "https://example.eks.us-west-2.amazonaws.com"
  cluster_certificate_authority_data = "dGVzdA==" # base64("test") — decodes cleanly for the provider config
  vpc_id                             = "vpc-0123456789abcdef0"
  gitops_repo_url                    = "https://github.com/nanohype/eks-gitops.git"
  enable_portal_reader               = false
}

# ── managed monitoring ON: the opencost gating label is present and equals the ──
# exact value the eks-gitops addons-opencost selector matches ("true"), and the
# monitoring/amp-workspace-id annotation opencost reads shares the same gate.
run "managed_monitoring_stamps_opencost_label" {
  command = plan

  variables {
    enable_managed_monitoring = true
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_cluster.metadata[0].labels["monitoring/managed"] == "true"
    error_message = "with managed monitoring enabled the cluster Secret must carry monitoring/managed=true (the label the eks-gitops addons-opencost generator selects on)"
  }

  # The coupling opencost depends on: the same gate that stamps the label also
  # stamps the AMP workspace-id annotation opencost templates its workspaceId from.
  assert {
    condition     = contains(keys(kubernetes_secret_v1.argocd_cluster.metadata[0].annotations), "monitoring/amp-workspace-id")
    error_message = "monitoring/managed and monitoring/amp-workspace-id must be stamped by the same gate, so an opencost-selected cluster always carries the annotation opencost reads"
  }
}

# ── managed monitoring OFF: the label is absent, so the opencost generator does ──
# not target this cluster (and the amp-workspace-id annotation it would read is
# absent too).
run "no_managed_monitoring_omits_opencost_label" {
  command = plan

  variables {
    enable_managed_monitoring = false
  }

  assert {
    condition     = !contains(keys(kubernetes_secret_v1.argocd_cluster.metadata[0].labels), "monitoring/managed")
    error_message = "without managed monitoring the cluster Secret must not carry monitoring/managed, or opencost would target a cluster that lacks the AMP annotation and can never render"
  }

  assert {
    condition     = !contains(keys(kubernetes_secret_v1.argocd_cluster.metadata[0].annotations), "monitoring/amp-workspace-id")
    error_message = "without managed monitoring the amp-workspace-id annotation must also be absent"
  }
}
