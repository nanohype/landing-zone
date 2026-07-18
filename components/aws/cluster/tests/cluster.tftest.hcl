# Unit tests for the cluster component — the root of the platform's dependency
# chain (EKS + secrets-encryption KMS + addon IRSA + the per-cluster subnet-tag
# handoff). The wrapped community EKS / Karpenter / KMS modules are exercised
# upstream; what THIS component owns, and what a silent regression would quietly
# break, is its own composition logic:
#
#   1. env-first cluster name — local.cluster_name = "<environment>-<cluster_name>"
#      feeds every cluster-scoped IAM/KMS/S3 name and the ownership tag; inverting
#      or doubling it collides co-located clusters or breaks cross-repo contracts.
#   2. subnet-ownership tag handoff — in create mode the cluster stamps
#      kubernetes.io/cluster/<cluster>=shared on the shared subnets; in the
#      cross-account adopt topology (stamp_subnet_tags=false) it stamps NONE, because
#      a participant cannot tag a foreign-owned subnet (the owner does it instead).
#   3. permissions-boundary conversion — the unset "" default becomes null (no
#      boundary), and a real ARN flows through unchanged, so IAM never gets a literal
#      empty-string boundary.
#   4. secure-by-default guards — public API endpoint requires a non-empty CIDR
#      allow-list; the base-name length budget, cluster_version shape, and system
#      node disk floor are all enforced at variable validation.
#
# PROVIDER STRATEGY: mock the aws/time/tls providers with valid computed defaults
# (ARNs, AZ lists, the EKS cluster's OIDC issuer + CA) so the wrapped modules plan
# offline with no credentials or network. The assertions read the component's own
# locals + root resources, so they test this component's logic directly.

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
  region             = "us-west-2"
  environment        = "development"
  team               = "platform"
  vpc_id             = "vpc-0mock"
  private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
  public_subnet_ids  = ["subnet-x", "subnet-y", "subnet-z"]
}

# ── Invariant 1: env-first cluster name + tags ──
run "cluster_name_is_env_first" {
  command = plan

  assert {
    condition     = local.cluster_name == "development-platform"
    error_message = "local.cluster_name must be <environment>-<cluster_name> (env-first), e.g. development-platform"
  }
  assert {
    condition     = local.tags["Component"] == "cluster" && local.tags["Team"] == "platform"
    error_message = "local.tags must carry Component=cluster and Team=<var.team>"
  }
  # The mocked EKS cluster's OIDC issuer is stripped of its scheme for the IAM
  # condition-key form every IRSA trust uses.
  assert {
    condition     = local.oidc_issuer == "oidc.eks.us-west-2.amazonaws.com/id/MOCK"
    error_message = "local.oidc_issuer must be the issuer URL with https:// stripped"
  }
}

# ── Invariant 2: create-mode subnet-ownership tags stamped on every subnet ──
run "subnet_ownership_tags_stamped_in_create_mode" {
  command = plan

  assert {
    condition     = length(aws_ec2_tag.subnet_cluster_ownership) == 6
    error_message = "stamp_subnet_tags = true (default) must stamp one ownership tag per subnet (3 private + 3 public = 6)"
  }
  assert {
    condition     = aws_ec2_tag.subnet_cluster_ownership["subnet-a"].key == "kubernetes.io/cluster/development-platform"
    error_message = "the ownership tag key must be kubernetes.io/cluster/<cluster> (cluster in the KEY, so siblings coexist)"
  }
  assert {
    condition     = aws_ec2_tag.subnet_cluster_ownership["subnet-a"].value == "shared"
    error_message = "the ownership tag value must be 'shared'"
  }
}

# ── Invariant 2 (other half): adopt topology stamps NO subnet tags ──
run "subnet_tags_gated_off_in_adopt_topology" {
  command = plan

  variables {
    stamp_subnet_tags = false
  }

  assert {
    condition     = length(aws_ec2_tag.subnet_cluster_ownership) == 0
    error_message = "stamp_subnet_tags = false must stamp NO ownership tags — a participant cannot tag a foreign-owned subnet"
  }
}

# ── Invariant 3: permissions-boundary conversion ──
run "permissions_boundary_empty_becomes_null" {
  command = plan

  assert {
    condition     = local.cluster_permissions_boundary == null
    error_message = "the unset (empty-string) boundary must convert to null, so IAM roles attach no boundary"
  }
}

run "permissions_boundary_arn_flows_through" {
  command = plan

  variables {
    cluster_permissions_boundary_arn = "arn:aws:iam::123456789012:policy/eks-fleet/vend-boundary"
  }

  assert {
    condition     = local.cluster_permissions_boundary == "arn:aws:iam::123456789012:policy/eks-fleet/vend-boundary"
    error_message = "a real boundary ARN must flow through local.cluster_permissions_boundary unchanged"
  }
}

# ── Invariant 4: a public API endpoint with no allow-list is rejected ──
run "public_endpoint_requires_allowlist" {
  command = plan

  variables {
    cluster_endpoint_public_access = true
    # deliberately no cidrs — must be rejected, never defaulted to 0.0.0.0/0
  }

  expect_failures = [
    var.cluster_endpoint_public_access_cidrs,
  ]
}

# ── Invariant 4: the base-name length budget is enforced ──
run "cluster_name_length_budget_enforced" {
  command = plan

  variables {
    # 13 chars — over the 12-char budget the account+region-qualified bucket names need.
    cluster_name = "toolongcluste"
  }

  expect_failures = [
    var.cluster_name,
  ]
}

# ── Invariant 4: cluster_version must be major.minor only ──
run "cluster_version_must_be_major_minor" {
  command = plan

  variables {
    cluster_version = "v1.36.2"
  }

  expect_failures = [
    var.cluster_version,
  ]
}

# ── Invariant 4: the system node disk floor guards against the DiskPressure bug ──
run "system_node_disk_floor_enforced" {
  command = plan

  variables {
    system_node_disk_size = 20
  }

  expect_failures = [
    var.system_node_disk_size,
  ]
}
