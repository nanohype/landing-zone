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
# Runs at command = plan against mocked aws/kubernetes/helm/kubectl/github/tls
# providers. The Secret's metadata is a plain merge()/jsonencode of variables and
# mocked SSM reads, so the labels and annotations render for real at plan time.
#
# github and tls are mocked even though the default tenants_repo_url = "" leaves
# the deploy-key resources at count 0: a resource at count 0 still puts its
# provider in the graph, so a real github provider is configured on every run.
# Configured with an empty owner and a GITHUB_TOKEN in the environment, it looks
# up the token's user and organisation on api.github.com, so an unmocked suite
# makes live GitHub calls, and passes or fails on the caller's token, wherever
# one is set. The tenants-repo runs at the end set the URL and assert what the
# deploy key and ArgoCD's repository Secret are given.

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
mock_provider "github" {}
mock_provider "tls" {}

variables {
  environment                        = "staging"
  region                             = "us-east-1"
  cluster_name                       = "staging-platform"
  cluster_endpoint                   = "https://example.eks.us-east-1.amazonaws.com"
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

# ── managed-monitoring ON: the Loki + Tempo S3 bucket annotations are stamped by ──
# the same gate, so the addons-observability appset can back logs and traces with
# durable object storage instead of PVCs that die with the cluster.
run "managed_monitoring_stamps_loki_tempo_bucket_annotations" {
  command = plan

  variables {
    enable_managed_monitoring = true
  }

  assert {
    condition = (
      kubernetes_secret_v1.argocd_cluster.metadata[0].annotations["observability/loki-bucket"] == "mock-ssm-value"
      && kubernetes_secret_v1.argocd_cluster.metadata[0].annotations["observability/tempo-bucket"] == "mock-ssm-value"
    )
    error_message = "with managed monitoring enabled the cluster Secret must carry observability/loki-bucket and observability/tempo-bucket (read from the cluster-addons SSM parameters) — the S3 backends the addons-observability ApplicationSet injects"
  }
}

# ── managed-monitoring OFF (default): no Loki/Tempo bucket annotations, so the SSM ──
# reads never run and the appset falls back to filesystem storage.
run "no_managed_monitoring_omits_loki_tempo_annotations" {
  command = plan

  assert {
    condition = (
      !contains(keys(kubernetes_secret_v1.argocd_cluster.metadata[0].annotations), "observability/loki-bucket")
      && !contains(keys(kubernetes_secret_v1.argocd_cluster.metadata[0].annotations), "observability/tempo-bucket")
    )
    error_message = "without managed monitoring the cluster Secret must not carry the observability/*-bucket annotations — they are opt-in and their SSM parameters would not be read"
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
    error_message = "in create mode both network-config subnet CSVs must be empty — the Kyverno policy needs no explicit injection, but the ConfigMap must still exist so the record states create rather than leaving the mode to be inferred from absence"
  }
}

# ── network mode adopt: Secret carries network_mode=adopt + private subnet ──
# annotation (Karpenter via addons-operations-kustomize), never the public one
# (nothing reads it). network-config ConfigMap carries both populated CSVs for
# Kyverno scheme-aware LB injection. Explicit subnet IDs because RAM hides owner
# subnet tags from participant accounts.
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
    error_message = "adopt mode must publish the private subnet IDs as a comma-joined Secret annotation for Karpenter"
  }

  assert {
    condition     = !contains(keys(kubernetes_secret_v1.argocd_cluster.metadata[0].annotations), "network/public-subnet-ids")
    error_message = "adopt mode must NOT publish network/public-subnet-ids on the Secret — Kyverno reads the ConfigMap, and nothing else reads a public annotation"
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

# ── observability tier: always-set, both values ────────────────────────────────
# The label is what the eks-gitops generators select on to decide whether a
# cluster gets the in-cluster LGTM stack or CloudWatch alone. It is unconditional
# for the same reason network_mode is: a generator matches a VALUE, it cannot
# branch on a key's absence, so a conditional label would make every full-tier
# generator silently match nothing on a cluster that simply predates it.
run "floor_tier_is_labelled" {
  command = plan

  variables {
    observability_tier = "floor"
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_cluster.metadata[0].labels["observability/tier"] == "floor"
    error_message = "a floor cluster's Secret must carry observability/tier=floor — the label is always set, never omitted"
  }
}

run "full_tier_is_labelled" {
  command = plan

  variables {
    observability_tier = "full"
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_cluster.metadata[0].labels["observability/tier"] == "full"
    error_message = "a full cluster's Secret must carry observability/tier=full"
  }
}

# Born light. A vended cluster that never says otherwise gets the cheap tier;
# opting up is a deliberate act, and every existing cluster pins full explicitly
# rather than relying on this.
run "tier_defaults_to_floor" {
  command = plan

  assert {
    condition     = kubernetes_secret_v1.argocd_cluster.metadata[0].labels["observability/tier"] == "floor"
    error_message = "observability_tier must default to floor so a new cluster is born light"
  }
}

# ── tenants repo unset (default): no deploy key, no key pair and no repository ──
# Secret exist, so a cluster that pulls no private tenants repo holds no
# credential for one.
run "no_tenants_repo_creates_no_deploy_key_or_credential" {
  command = plan

  assert {
    condition     = length(github_repository_deploy_key.argocd_tenants) == 0 && length(tls_private_key.argocd_tenants) == 0 && length(kubernetes_secret_v1.argocd_tenants_repo) == 0
    error_message = "with tenants_repo_url unset, cluster-bootstrap must create no deploy key, key pair or ArgoCD repository Secret"
  }
}

# ── tenants repo as an SSH URL: ArgoCD's deploy key is read-only, named for the ──
# cluster and registered on the repository and owner the URL names, and the
# repository Secret ArgoCD reads carries that same URL. A key with write access
# would let anyone who reads the cluster's ArgoCD Secret push to the tenants
# repo; a wrong owner would register the key on another account's repository of
# the same name.
run "tenants_repo_ssh_url_registers_a_read_only_deploy_key" {
  command = plan

  variables {
    tenants_repo_url = "git@github.com:nanohype/tenants.git"
  }

  assert {
    condition     = github_repository_deploy_key.argocd_tenants[0].read_only == true
    error_message = "ArgoCD's deploy key on the tenants repo must be read-only"
  }

  assert {
    condition     = github_repository_deploy_key.argocd_tenants[0].repository == "tenants" && local.tenants_repo_owner == "nanohype"
    error_message = "git@github.com:nanohype/tenants.git must register the key on repository tenants with the github provider's owner nanohype"
  }

  assert {
    condition     = github_repository_deploy_key.argocd_tenants[0].title == "argocd-staging-platform-ro"
    error_message = "the deploy key's title must name the cluster (argocd-<cluster_name>-ro), so each cluster's key can be found and revoked on its own"
  }

  assert {
    condition     = tls_private_key.argocd_tenants[0].algorithm == "ED25519"
    error_message = "the deploy key pair must be ED25519"
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_tenants_repo[0].data["url"] == "git@github.com:nanohype/tenants.git" && kubernetes_secret_v1.argocd_tenants_repo[0].data["type"] == "git"
    error_message = "ArgoCD's repository Secret must carry the tenants repo URL as a git repository"
  }

  assert {
    condition     = kubernetes_secret_v1.argocd_tenants_repo[0].metadata[0].labels["argocd.argoproj.io/secret-type"] == "repository" && kubernetes_secret_v1.argocd_tenants_repo[0].metadata[0].namespace == "argocd"
    error_message = "the repository Secret must be labelled argocd.argoproj.io/secret-type=repository in ArgoCD's namespace, or ArgoCD never reads it"
  }
}

# ── tenants repo as an HTTPS URL: the same repository and owner as the SSH form. ──
run "tenants_repo_https_url_names_the_same_repository" {
  command = plan

  variables {
    tenants_repo_url = "https://github.com/nanohype/tenants.git"
  }

  assert {
    condition     = github_repository_deploy_key.argocd_tenants[0].repository == "tenants" && local.tenants_repo_owner == "nanohype"
    error_message = "https://github.com/nanohype/tenants.git must register the key on repository tenants with the github provider's owner nanohype"
  }
}
