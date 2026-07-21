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

# ── argo-workflows ON: the artifact-bucket annotation is stamped from the SSM ──
# parameter cluster-addons publishes, so the argo-workflows ApplicationSet can wire
# the real per-cluster S3 artifact repository. Gated on enable_argo_workflows — the
# same seam velero/backup-bucket and external-dns/domain-filter use.
run "argo_workflows_stamps_artifact_bucket_annotation" {
  command = plan

  variables {
    enable_argo_workflows = true
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_cluster.metadata[0].annotations["argo-workflows/artifact-bucket"] == "mock-ssm-value"
    error_message = "with Argo Workflows enabled the cluster Secret must carry the argo-workflows/artifact-bucket annotation (read from the cluster-addons SSM parameter) — the S3 artifact repository the argo-workflows ApplicationSet injects"
  }
}

# ── argo-workflows OFF (default): no artifact-bucket annotation, so the SSM read ──
# never runs on a cluster that publishes no bucket, and the argo-workflows
# generator does not target it.
run "no_argo_workflows_omits_artifact_bucket_annotation" {
  command = plan

  assert {
    condition     = !contains(keys(kubernetes_secret_v1.argocd_cluster.metadata[0].annotations), "argo-workflows/artifact-bucket")
    error_message = "without Argo Workflows the cluster Secret must not carry argo-workflows/artifact-bucket — the annotation is opt-in and its SSM parameter would not exist"
  }
}

# ── network mode create: the cluster Secret carries the network_mode label so ──
# eks-gitops generators can select on it unconditionally, publishes no subnet
# annotations (a create cluster's load balancers auto-discover subnets by the ELB
# role tags it stamps), and the network-config ConfigMap the eks-gitops Kyverno
# subnet-injection policy reads exists with empty CSVs. Subnet IDs are set here
# even though the mode is create — the live envcommon passes network's outputs
# through unconditionally, so this proves the component's own mode gate is
# load-bearing: create-mode subnets are dropped, not just absent by default.
run "create_mode_publishes_empty_network_config" {
  command = plan

  variables {
    network_mode       = "create"
    private_subnet_ids = ["subnet-1", "subnet-2", "subnet-3"]
    public_subnet_ids  = ["subnet-4", "subnet-5", "subnet-6"]
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_cluster.metadata[0].labels["network_mode"] == "create"
    error_message = "in create mode the cluster Secret must carry network_mode=create (always set, so a generator can select on it unconditionally)"
  }

  assert {
    condition     = !contains(keys(kubernetes_secret_v1.argocd_cluster.metadata[0].annotations), "network/private-subnet-ids")
    error_message = "in create mode no network/private-subnet-ids annotation must be published — a create cluster discovers subnets by tag"
  }

  assert {
    condition     = !contains(keys(kubernetes_secret_v1.argocd_cluster.metadata[0].annotations), "network/public-subnet-ids")
    error_message = "in create mode no network/public-subnet-ids annotation must be published"
  }

  assert {
    condition     = kubernetes_config_map_v1.network_config.data["network_mode"] == "create"
    error_message = "the kube-system/network-config ConfigMap must record network_mode=create"
  }

  assert {
    condition     = kubernetes_config_map_v1.network_config.data["private_subnet_ids"] == "" && kubernetes_config_map_v1.network_config.data["public_subnet_ids"] == ""
    error_message = "in create mode both network-config subnet CSVs must be empty — the Kyverno policy needs no explicit injection, but the ConfigMap must still exist so its context lookup never misses"
  }
}

# ── network mode adopt: the Secret carries network_mode=adopt plus both subnet-ID ──
# annotations, and the network-config ConfigMap carries both populated CSVs — the
# explicit subnet IDs an adopt cluster's load balancer controller can't discover by
# tag, because RAM hides owner subnet tags from participant accounts. Both CSVs
# because scheme-aware injection needs private (internal LB) and public
# (internet-facing LB) subnets.
run "adopt_mode_publishes_both_subnet_csvs" {
  command = plan

  variables {
    network_mode       = "adopt"
    private_subnet_ids = ["subnet-0aaa", "subnet-0bbb", "subnet-0ccc"]
    public_subnet_ids  = ["subnet-0ddd", "subnet-0eee", "subnet-0fff"]
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_cluster.metadata[0].labels["network_mode"] == "adopt"
    error_message = "in adopt mode the cluster Secret must carry network_mode=adopt"
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_cluster.metadata[0].annotations["network/private-subnet-ids"] == "subnet-0aaa,subnet-0bbb,subnet-0ccc"
    error_message = "adopt mode must publish the private subnet IDs as a comma-joined annotation"
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_cluster.metadata[0].annotations["network/public-subnet-ids"] == "subnet-0ddd,subnet-0eee,subnet-0fff"
    error_message = "adopt mode must publish the public subnet IDs as a comma-joined annotation"
  }

  assert {
    condition     = kubernetes_config_map_v1.network_config.data["private_subnet_ids"] == "subnet-0aaa,subnet-0bbb,subnet-0ccc"
    error_message = "the network-config ConfigMap must carry the populated private subnet CSV in adopt mode"
  }

  assert {
    condition     = kubernetes_config_map_v1.network_config.data["public_subnet_ids"] == "subnet-0ddd,subnet-0eee,subnet-0fff"
    error_message = "the network-config ConfigMap must carry the populated public subnet CSV in adopt mode"
  }
}
