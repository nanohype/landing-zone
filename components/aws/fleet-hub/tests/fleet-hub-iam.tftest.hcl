# Unit tests for fleet-hub's IAM ceiling — the management-account twin of
# fleet-vend. fleet-hub is the same crown-jewel vend boundary as fleet-vend, one
# hop closer to the blast radius: the eks-fleet-crossplane role provisions clusters
# same-account and sts:AssumeRoles the vend roles cross-account. The same two things
# make that safe, and both are invariants a silent regression would quietly demolish:
#
#   1. The hub role's TRUST is a web-identity (IRSA) trust bound to EXACTLY the
#      crossplane-system/provider-opentofu ServiceAccount on the management cluster's
#      OIDC provider — never a wildcard sub, never a second principal. Widen the sub
#      condition or drop the OIDC provider binding and any pod that can mint a
#      projected token could assume the hub role and vend clusters at will.
#   2. The permissions boundary + identity policy together guarantee a compromised
#      hub session can build clusters but can NEVER mint or widen an unbounded IAM
#      principal: the boundary DENIES role-writes whose target lacks an approved
#      boundary and DENIES the org/account/user-mint escalation verbs, and the
#      identity policy's CreateRole is boundary-gated AND path-scoped to /eks-fleet/*
#      (never Resource="*").
#
# PROVIDER STRATEGY (B, real credential-less provider) — the twin of fleet-vend's.
# The hub trust is rendered by data.aws_iam_policy_document.hub_trust; a mock_provider
# mangles that data source into a non-JSON placeholder, so we run a REAL provider with
# skip_* flags (no creds, no network) so the policy document renders locally and for
# real, and override_data ONLY the two API-backed data sources (caller_identity,
# partition) so the account-qualified ARNs resolve. Every policy under assertion — the
# trust, the jsonencode boundary, the jsonencode identity policy — therefore renders
# with real content at plan time. The state bucket's SSE + policy hardening is asserted
# separately in fleet-hub.tftest.hcl, which pins the computed KMS/bucket ARNs it reads
# with a mock provider.

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
  environment       = "development"
  region            = "us-west-2"
  team              = "platform"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/TEST"
  oidc_issuer       = "https://oidc.eks.us-west-2.amazonaws.com/id/TEST"
  state_bucket_name = "test-fleet-state"
}

# ── Invariant 1: the hub trust is bound to exactly the provider-opentofu SA ──
# assume_role_policy is fed from aws_iam_policy_document.hub_trust, so asserting on
# the ROLE attribute proves the rendered trust AND that the role consumes it.
# Structural: find the web-identity statement, assert its Federated principal is the
# OIDC provider AND its "<issuer>:sub" condition pins the crossplane SA subject.
run "hub_trust_bound_to_provider_opentofu_sa" {
  command = plan

  # Exactly one Allow sts:AssumeRoleWithWebIdentity whose Federated principal is the
  # OIDC provider ARN, gated by a ":sub" condition equal to the crossplane SA. The
  # equality forbids a wildcard sub (which would let any pod's token assume the role)
  # and a second principal (which would render a list and fail).
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.hub.assume_role_policy).Statement :
      s if s.Effect == "Allow"
      && contains(try(tolist(s.Action), [s.Action]), "sts:AssumeRoleWithWebIdentity")
      && try(s.Principal.Federated, "") == var.oidc_provider_arn
      && anytrue([
        for k, v in try(s.Condition.StringEquals, {}) :
        endswith(k, ":sub") && v == "system:serviceaccount:crossplane-system:provider-opentofu"
      ])
    ]) == 1
    error_message = "hub trust must Allow sts:AssumeRoleWithWebIdentity to the OIDC provider, gated by a ':sub' condition pinning the crossplane-system/provider-opentofu SA (never a wildcard sub)"
  }

  # The same statement must also pin the STS audience — without it the token is not
  # scoped to sts.amazonaws.com and a differently-audienced projected token qualifies.
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role.hub.assume_role_policy).Statement :
      anytrue([for k, v in try(s.Condition.StringEquals, {}) : endswith(k, ":aud") && v == "sts.amazonaws.com"])
    ])
    error_message = "hub trust must pin the ':aud' condition to sts.amazonaws.com"
  }
}

# ── Invariant 2: the boundary DENIES unbounded role writes (the ceiling twin) ──
# Any role write performed under the hub boundary must target a role carrying an
# approved boundary (the hub boundary or the agent-platform tenant boundary). Flip
# this Deny to Allow, drop the condition, or widen the approved set and a capped
# session can mint an unbounded admin role. jsonencode → real JSON at plan time.
run "boundary_denies_unbounded_role_writes" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.hub_boundary.policy).Statement :
      s if try(s.Sid, "") == "DenyUnboundedRoleWrites"
      && s.Effect == "Deny"
      && contains(s.Action, "iam:CreateRole")
      && contains(s.Action, "iam:PutRolePermissionsBoundary")
      && try(s.Condition.ArnNotLike["iam:PermissionsBoundary"], null) == [
        "arn:aws:iam::123456789012:policy/eks-fleet/eks-fleet-hub-boundary",
        "arn:aws:iam::123456789012:policy/eks-agent-platform/development-*-agent-platform-tenant-boundary",
      ]
    ]) == 1
    error_message = "boundary must DENY iam:CreateRole/AttachRolePolicy/PutRolePolicy/PutRolePermissionsBoundary whose iam:PermissionsBoundary is not one of the two approved boundary ARNs"
  }
}

# ── Invariant 3: the boundary DENIES the escalation verbs outright ──
# No hub session may ever mint a human/long-lived principal, touch the org or
# account, or strip a permissions boundary off a role — regardless of what identity
# policy is attached under the boundary. Structural: find DenyEscalation by Sid.
run "boundary_denies_escalation_verbs" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.hub_boundary.policy).Statement :
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
# permitted ONLY when the target carries the hub boundary, AND only on roles under
# /eks-fleet/* — never Resource="*". Drop the condition and it's an unbounded role
# factory; widen the resource to "*" and it can rewrite any role in the account.
run "identity_cluster_role_write_is_boundary_gated_and_path_scoped" {
  command = plan

  # Boundary-gated: exactly one ManageClusterRolesWithBoundary statement, and its
  # iam:PermissionsBoundary condition pins the hub boundary ARN.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.hub.policy).Statement :
      s if try(s.Sid, "") == "ManageClusterRolesWithBoundary"
      && s.Effect == "Allow"
      && contains(s.Action, "iam:CreateRole")
      && try(s.Condition.StringEquals["iam:PermissionsBoundary"], "") == "arn:aws:iam::123456789012:policy/eks-fleet/eks-fleet-hub-boundary"
    ]) == 1
    error_message = "identity policy CreateRole/*RolePolicy must be gated by iam:PermissionsBoundary == the hub boundary ARN"
  }

  # Path-scoped: that same statement's Resource is the /eks-fleet/* role ARN, never "*".
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.hub.policy).Statement :
      try(s.Resource, "") == "arn:aws:iam::123456789012:role/eks-fleet/*" && try(s.Resource, "") != "*"
      if try(s.Sid, "") == "ManageClusterRolesWithBoundary"
    ])
    error_message = "identity policy role-write must be scoped to the /eks-fleet/* role ARN, never Resource=\"*\""
  }
}
