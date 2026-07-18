# Unit tests for the cluster-stack vend root — the first provider-opentofu
# Workspace in eks-fleet's Cluster composition. It wires network -> cluster (the
# tofu-native twin of the env-tree's cluster.hcl dependency chain) and vends one
# EKS cluster. The wrapped components (network, cluster) are exercised by their
# own suites; what THIS root owns, and what a silent regression would quietly
# demolish, is the composition logic in its locals:
#
#   1. The break-glass discovery tag. Every spoke resource carries
#      Cluster = <environment>-<cluster_name>. The break-glass unwedge teardown
#      targets a spoke by matching ProvisionedBy=eks-fleet AND this exact tag, so a
#      teardown can never reach a sibling spoke in the same account. Drop or mangle
#      the tag and a teardown either misses its target or over-reaches into a peer.
#   2. The lifecycle/expiry contract. An ephemeral spoke (ttl_days > 0) is tagged
#      Lifecycle=ephemeral + Expiry=<vend date + ttl_days>; the hub reaper deletes
#      the Cluster CR past Expiry. A persistent spoke (ttl_days = 0) is
#      Lifecycle=persistent and carries NO Expiry, so it is never auto-reaped.
#   3. Portal reaches the cluster read-only, NEVER admin. When wired, portal gets
#      an EKS access entry mapped to the portal-reader Kubernetes GROUP with NO AWS
#      managed access policy — the eks-gitops catalog binds that group to a narrow
#      read ClusterRole. A policy_associations block here would hand portal a
#      managed (admin/view-with-secrets) policy: a privilege-escalation regression.
#   4. Cross-account bootstrap gets cluster-admin, and only when asked. When the
#      hub bootstrap role is supplied it gets an access entry with the
#      AmazonEKSClusterAdminPolicy scoped to the cluster; same-account (empty) adds
#      none, because the creator is already admin.
#
# PROVIDER STRATEGY: mock the aws/time/tls providers with valid computed defaults
# (ARNs, AZ lists, the EKS cluster's OIDC issuer + CA, a stable vend timestamp) so
# the wrapped EKS/Karpenter/VPC community modules plan offline with no credentials
# or network. The assertions read the ROOT's own locals, so they test this root's
# composition logic directly, independent of what the wrapped modules render.

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
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:role/creator" }
  }
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-west-2a", "us-west-2b", "us-west-2c"], zone_ids = ["usw2-az1", "usw2-az2", "usw2-az3"] }
  }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/mock" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::123456789012:policy/mock" } }
  mock_resource "aws_kms_key" { defaults = { arn = "arn:aws:kms:us-west-2:123456789012:key/mock" } }
  mock_resource "aws_sqs_queue" { defaults = { arn = "arn:aws:sqs:us-west-2:123456789012:mock", url = "https://sqs.us-west-2.amazonaws.com/123456789012/mock" } }
  mock_resource "aws_cloudwatch_log_group" { defaults = { arn = "arn:aws:logs:us-west-2:123456789012:log-group:mock" } }
  mock_resource "aws_security_group" { defaults = { id = "sg-mock", arn = "arn:aws:ec2:us-west-2:123456789012:security-group/sg-mock" } }
  mock_resource "aws_launch_template" { defaults = { id = "lt-mock0000000000000", latest_version = 1 } }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-west-2:123456789012:cluster/mock"
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-west-2.amazonaws.com/id/MOCK" }] }]
      certificate_authority = [{ data = "bW9jay1jYQ==" }]
    }
  }
}
mock_provider "time" {
  mock_resource "time_static" { defaults = { rfc3339 = "2026-01-01T00:00:00Z" } }
}
mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = { certificates = [{ sha1_fingerprint = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280" }] }
  }
}

variables {
  region       = "us-west-2"
  environment  = "development"
  team         = "platform"
  cluster_name = "platform"
}

# ── Invariant 1 + 2: discovery tag + ephemeral lifecycle/expiry ──────────────
run "ephemeral_spoke_carries_discovery_tag_and_expiry" {
  command = plan

  variables {
    ttl_days = 7
  }

  assert {
    condition     = local.spoke_tags["Cluster"] == "development-platform"
    error_message = "every spoke resource must carry Cluster = <environment>-<cluster_name> — the break-glass teardown's per-spoke discovery key"
  }
  assert {
    condition     = local.lifecycle_tags["Lifecycle"] == "ephemeral"
    error_message = "a ttl_days > 0 spoke must be tagged Lifecycle=ephemeral so the hub reaper adopts it"
  }
  # time_static.vend is mocked to 2026-01-01T00:00:00Z, so +7d = 2026-01-08.
  assert {
    condition     = local.lifecycle_tags["Expiry"] == "2026-01-08"
    error_message = "an ephemeral spoke's Expiry must be vend date + ttl_days (YYYY-MM-DD)"
  }
  # The Expiry tag rides in the same spoke_tags every resource gets.
  assert {
    condition     = local.spoke_tags["Expiry"] == "2026-01-08"
    error_message = "Expiry must be merged into spoke_tags so it lands on the cluster's resources"
  }
}

# ── Invariant 2 (other half): a persistent spoke has NO expiry ───────────────
run "persistent_spoke_has_no_expiry" {
  command = plan

  variables {
    ttl_days = 0
  }

  assert {
    condition     = local.lifecycle_tags["Lifecycle"] == "persistent"
    error_message = "a ttl_days = 0 spoke must be tagged Lifecycle=persistent"
  }
  assert {
    condition     = !contains(keys(local.lifecycle_tags), "Expiry")
    error_message = "a persistent spoke must carry NO Expiry tag — it is never auto-reaped"
  }
}

# ── Invariant 3: portal access entry is read-only, never a managed policy ─────
run "portal_access_entry_is_read_only" {
  command = plan

  variables {
    portal_access_role_arn = "arn:aws:iam::123456789012:role/portal-spoke"
  }

  # Mapped to the portal-reader Kubernetes group — the eks-gitops catalog binds
  # that group to a narrow read ClusterRole (no Secrets).
  assert {
    condition     = local.portal_access_entries["portal-read"].kubernetes_groups == ["portal-reader"]
    error_message = "portal's access entry must map to the portal-reader Kubernetes group"
  }
  # And it must carry NO AWS managed access policy — a policy_associations block
  # here would hand portal a managed (admin/view-with-secrets) policy.
  assert {
    condition     = !contains(keys(local.portal_access_entries["portal-read"]), "policy_associations")
    error_message = "portal's access entry must NOT carry policy_associations — read access comes from the portal-reader group binding, never an AWS managed access policy"
  }
  # Portal wired but no bootstrap role: no bootstrap admin entry.
  assert {
    condition     = length(local.bootstrap_access_entries) == 0
    error_message = "no bootstrap_access_role_arn means no cluster-admin access entry (same-account creator is already admin)"
  }
}

# ── Invariant 4: cross-account bootstrap gets cluster-admin, scoped ──────────
run "bootstrap_access_entry_grants_cluster_admin" {
  command = plan

  variables {
    bootstrap_access_role_arn = "arn:aws:iam::123456789012:role/eks-fleet-hub"
  }

  assert {
    condition     = endswith(local.bootstrap_access_entries["hub-bootstrap"].policy_associations.admin.policy_arn, "cluster-access-policy/AmazonEKSClusterAdminPolicy")
    error_message = "the hub bootstrap access entry must attach the AmazonEKSClusterAdminPolicy"
  }
  assert {
    condition     = local.bootstrap_access_entries["hub-bootstrap"].policy_associations.admin.access_scope.type == "cluster"
    error_message = "the hub bootstrap admin policy must be scoped to the whole cluster"
  }
  # Bootstrap wired but no portal role: no portal read entry.
  assert {
    condition     = length(local.portal_access_entries) == 0
    error_message = "no portal_access_role_arn means no portal read access entry"
  }
}
