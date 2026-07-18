# Unit tests for the cluster-bootstrap vend root — the second provider-opentofu
# Workspace in eks-fleet's Cluster composition. It runs AFTER the cluster is Ready
# and wraps two components: agent-iam (the operator IRSA role + tenant boundary,
# AWS) and cluster-bootstrap (Cilium + ArgoCD + the in-cluster ArgoCD Secret,
# k8s/helm). This root is the tofu-native twin of the env-tree's
# agent-iam + cluster-bootstrap leaves; a silent break here fails every spoke vend
# at the post-cluster step, so this suite guards the invariants that keep the vend
# safe and honest:
#
#   1. The composition WIRES END TO END. A clean plan produces the operator IRSA
#      role ARN — proving agent-iam receives every required input (cluster_name +
#      data_kms_key_arn have no defaults; omitting either, as the pre-consolidation
#      wrapper did, fails the plan). This is the regression that broke the vend path.
#   2. The "cluster not Ready" guard. cluster_endpoint is patched from
#      Cluster.status.clusterEndpoint, empty until the cluster reaches Ready; the
#      validation turns an early reconcile into a clear waiting message instead of a
#      cryptic k8s-provider error. Dropping it lets a bootstrap apply run against an
#      empty endpoint.
#   3. The GitOps repo is a real git URL, and network_mode is create|adopt. The
#      app-of-apps points every spoke at this URL; a non-git value or a bad mode
#      must fail at plan, never at apply against a live cluster.
#
# PROVIDER STRATEGY: mock the aws and tls providers (valid mock_data so
# agent-iam's IAM policy documents + the cluster-auth token render). The
# cluster-bootstrap COMPONENT self-declares its kubernetes/helm/kubectl/github
# providers inline — a legacy module OpenTofu cannot override with mock_provider,
# so those must NOT be given mock_provider blocks: declaring a mock for a provider
# that is actually configured inside a legacy child module makes tofu test resolve
# the child's provider config against the mock's empty schema, so every real
# argument (host, token, …) reports as unexpected. Leaving them un-mocked lets the
# real plugins load their schemas and plan offline — cluster_certificate_authority_data
# is a real (throwaway, self-signed, key-less) CA the providers parse without
# network or credentials, so helm_release/k8s resources plan as creates.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com", reverse_dns_prefix = "com.amazonaws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:iam::123456789012:user/test", user_id = "AIDTEST" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-west-2", id = "us-west-2" }
  }
}
mock_provider "tls" {}

variables {
  region                             = "us-west-2"
  environment                        = "development"
  team                               = "platform"
  cluster_name                       = "platform"
  cluster_endpoint                   = "https://EXAMPLE.gr7.us-west-2.eks.amazonaws.com"
  cluster_certificate_authority_data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJlRENDQVIrZ0F3SUJBZ0lVQzBqN3dtOU55YXFORnJ1U2tWNUVYUVdFenE4d0NnWUlLb1pJemowRUF3SXcKRWpFUU1BNEdBMVVFQXd3SGRHVnpkQzFqWVRBZUZ3MHlOakEzTVRnd09EQTNNREJhRncwek5qQTNNVFV3T0RBMwpNREJhTUJJeEVEQU9CZ05WQkFNTUIzUmxjM1F0WTJFd1dUQVRCZ2NxaGtqT1BRSUJCZ2dxaGtqT1BRTUJCd05DCkFBUloyalRvc2hPM0RmTmNYT2FMNnVJOENuSEUwWWFQTzFPdXFqTXB4c3EzSWxqR3JUM1dxbUhYRmRFTk5mNXUKTmJycUxTYmtqTHJvdmIvbDRYNXJCQ2tjbzFNd1VUQWRCZ05WSFE0RUZnUVVlWWo1c0NsNFJmdjRhRmEvaTY4QwpvNVlMcGZjd0h3WURWUjBqQkJnd0ZvQVVlWWo1c0NsNFJmdjRhRmEvaTY4Q281WUxwZmN3RHdZRFZSMFRBUUgvCkJBVXdBd0VCL3pBS0JnZ3Foa2pPUFFRREFnTkhBREJFQWlCTHRqUVA4NWg2VWsrQklKU2JXelBHdGVIL09yRmYKSS9pZ2tWTjllTlc2TEFJZ0lMd3VTankrNXhuVm4xMk5sSEh1bC9NQWtjcStodXBjdnNFZ0N0NmdZbnM9Ci0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K"
  oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/TEST"
  oidc_issuer                        = "oidc.eks.us-west-2.amazonaws.com/id/TEST"
  vpc_id                             = "vpc-0123456789abcdef0"
  data_kms_key_arn                   = "arn:aws:kms:us-west-2:123456789012:key/12345678-1234-1234-1234-123456789012"
  operator_permissions_boundary_arn  = "arn:aws:iam::123456789012:policy/eks-fleet/eks-fleet-hub-boundary"
  gitops_repo_url                    = "https://github.com/nanohype/eks-gitops"
}

# ── Invariant 1: the composition wires end to end ────────────────────────────
run "composition_wires_end_to_end" {
  command = plan

  assert {
    condition     = output.operator_role_arn != ""
    error_message = "cluster-bootstrap must surface agent-iam's operator IRSA role ARN — a null/empty value means the agent-iam wiring (cluster_name + data_kms_key_arn) regressed"
  }
}

# ── Invariant 2: the not-Ready guard rejects an empty endpoint ───────────────
run "empty_endpoint_is_rejected" {
  command = plan

  variables {
    cluster_endpoint = ""
  }

  expect_failures = [var.cluster_endpoint]
}

# ── Invariant 3a: the GitOps repo URL must be a git URL ──────────────────────
run "non_git_gitops_url_is_rejected" {
  command = plan

  variables {
    gitops_repo_url = "not-a-git-url"
  }

  expect_failures = [var.gitops_repo_url]
}

# ── Invariant 3b: network_mode is create|adopt only ──────────────────────────
run "invalid_network_mode_is_rejected" {
  command = plan

  variables {
    network_mode = "bridge"
  }

  expect_failures = [var.network_mode]
}
