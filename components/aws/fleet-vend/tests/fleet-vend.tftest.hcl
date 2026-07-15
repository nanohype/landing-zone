# Unit tests for fleet-vend — the cross-account role the eks-fleet hub assumes to
# provision an EKS cluster in THIS workload account. fleet-vend is the vend/spoke
# boundary: a management-account role sts:AssumeRoles into this account and then
# runs as the vend role to stand up infra. Two things make that safe, and both are
# crown-jewel invariants a silent regression would quietly demolish:
#
#   1. The vend role's TRUST is scoped to exactly the hub principal (never "*") and
#      gated by an sts:ExternalId (confused-deputy guard). Widen the principal to
#      "*" or drop the ExternalId and any principal in any account that learns the
#      role ARN can assume the vend role — a full cross-account takeover.
#   2. The permissions boundary + identity policy together guarantee a compromised
#      vend session can build clusters but can NEVER mint or widen an unbounded IAM
#      principal: the boundary DENIES role-writes whose target lacks an approved
#      boundary and DENIES the org/account/user-mint escalation verbs, and the
#      identity policy's CreateRole is boundary-gated AND path-scoped to /eks-fleet/*
#      (never Resource="*").
#
# PROVIDER STRATEGY (B, real credential-less provider). The vend trust is rendered
# by data.aws_iam_policy_document.vend_trust; a mock_provider mangles that data
# source into a non-JSON placeholder, so we run a REAL provider with skip_* flags
# (no creds, no network) so the policy document renders locally and for real, and
# override_data ONLY the two API-backed data sources (caller_identity, partition)
# so the account-qualified ARNs resolve. Every policy under assertion — the trust,
# the jsonencode boundary, the jsonencode identity policy — therefore renders with
# real content at plan time. No assertion reads an override_data'd stub value.

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/test"
    user_id    = "AIDTEST"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition          = "aws"
    dns_suffix         = "amazonaws.com"
    reverse_dns_prefix = "com.amazonaws"
  }
}

variables {
  environment  = "dev"
  region       = "us-west-2"
  team         = "platform"
  hub_role_arn = "arn:aws:iam::999999999999:role/dev-eks-fleet-crossplane"
  external_id  = "test-external-id"
}

# ── Invariant 1: the vend trust is scoped to the hub principal, gated by ExternalId ──
# The whole cross-account model rests here. assume_role_policy is fed from
# aws_iam_policy_document.vend_trust, so asserting on the ROLE attribute proves the
# rendered trust AND that the role actually consumes it. Structural: find the
# AssumeRole statement, assert its exact principal + condition — never positional.
run "vend_trust_scoped_to_hub_with_externalid" {
  command = plan

  # Principal.AWS must equal the hub role ARN exactly. Equality inherently forbids
  # "*" (a wildcard renders {"AWS":"*"} and fails) and forbids sneaking a second
  # trusted principal in (that renders a list and fails).
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.vend.assume_role_policy).Statement :
      s if s.Effect == "Allow"
      && contains(try(tolist(s.Action), [s.Action]), "sts:AssumeRole")
      && try(s.Principal.AWS, "") == var.hub_role_arn
    ]) == 1
    error_message = "vend trust must Allow sts:AssumeRole to EXACTLY the hub_role_arn principal (never \"*\", never an extra principal)"
  }

  # The same statement must be gated by sts:ExternalId == var.external_id. Without
  # it the trust degrades to bare account trust — the confused-deputy guard is gone.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.vend.assume_role_policy).Statement :
      s if try(s.Principal.AWS, "") == var.hub_role_arn
      && try(s.Condition.StringEquals["sts:ExternalId"], "") == var.external_id
    ]) == 1
    error_message = "vend trust must be gated by StringEquals sts:ExternalId == external_id (confused-deputy guard)"
  }
}

# ── Invariant 2: the boundary DENIES unbounded role writes (the ceiling twin) ──
# This is the guarantee that survives identity-policy tampering: any role write
# performed under the vend boundary must target a role carrying an approved
# boundary (the vend boundary or the agent-platform tenant boundary). Flip this
# Deny to Allow, drop the condition, or widen the approved set and a capped session
# can mint an unbounded admin role. jsonencode → real JSON at plan time.
run "boundary_denies_unbounded_role_writes" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.vend_boundary.policy).Statement :
      s if try(s.Sid, "") == "DenyUnboundedRoleWrites"
      && s.Effect == "Deny"
      && contains(s.Action, "iam:CreateRole")
      && contains(s.Action, "iam:PutRolePermissionsBoundary")
      && try(s.Condition.StringNotEquals["iam:PermissionsBoundary"], null) == [
        "arn:aws:iam::123456789012:policy/eks-fleet/dev-eks-fleet-vend-boundary",
        "arn:aws:iam::123456789012:policy/eks-agent-platform/dev-eks-agent-platform-tenant-boundary",
      ]
    ]) == 1
    error_message = "boundary must DENY iam:CreateRole/AttachRolePolicy/PutRolePolicy/PutRolePermissionsBoundary whose iam:PermissionsBoundary is not one of the two approved boundary ARNs"
  }
}

# ── Invariant 3: the boundary DENIES the escalation verbs outright ──
# No vend session may ever mint a human/long-lived principal, touch the org or
# account, or strip a permissions boundary off a role — regardless of what identity
# policy is attached under the boundary. Structural: find DenyEscalation by Sid.
run "boundary_denies_escalation_verbs" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.vend_boundary.policy).Statement :
      s if try(s.Sid, "") == "DenyEscalation"
      && s.Effect == "Deny"
      && contains(s.Action, "organizations:*")
      && contains(s.Action, "account:*")
      && contains(s.Action, "iam:CreateUser")
      && contains(s.Action, "iam:CreateAccessKey")
      && contains(s.Action, "iam:DeleteRolePermissionsBoundary")
    ]) == 1
    error_message = "boundary must Deny organizations:*, account:*, iam:CreateUser, iam:CreateAccessKey, and iam:DeleteRolePermissionsBoundary (the escalation verbs)"
  }
}

# ── Invariant 4: the identity policy's role-write is boundary-gated AND path-scoped ──
# The identity-layer half of invariant 2. CreateRole/*RolePolicy on cluster roles is
# permitted ONLY when the target carries the vend boundary, AND only on roles under
# /eks-fleet/* — never Resource="*". Drop the condition and it's an unbounded role
# factory; widen the resource to "*" and it can rewrite any role in the account.
run "identity_cluster_role_write_is_boundary_gated_and_path_scoped" {
  command = plan

  # Boundary-gated: exactly one ManageClusterRolesWithBoundary statement, and its
  # iam:PermissionsBoundary condition pins the vend boundary ARN.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.vend.policy).Statement :
      s if try(s.Sid, "") == "ManageClusterRolesWithBoundary"
      && s.Effect == "Allow"
      && contains(s.Action, "iam:CreateRole")
      && try(s.Condition.StringEquals["iam:PermissionsBoundary"], "") == "arn:aws:iam::123456789012:policy/eks-fleet/dev-eks-fleet-vend-boundary"
    ]) == 1
    error_message = "identity policy CreateRole/*RolePolicy must be gated by iam:PermissionsBoundary == the vend boundary ARN"
  }

  # Path-scoped: that same statement's Resource is the /eks-fleet/* role ARN, never "*".
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.vend.policy).Statement :
      try(s.Resource, "") == "arn:aws:iam::123456789012:role/eks-fleet/*" && try(s.Resource, "") != "*"
      if try(s.Sid, "") == "ManageClusterRolesWithBoundary"
    ])
    error_message = "identity policy role-write must be scoped to the /eks-fleet/* role ARN, never Resource=\"*\""
  }
}
