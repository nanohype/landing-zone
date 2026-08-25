# Unit tests for fleet-unwedge — the cross-account credential portal assumes to
# delete a wedged vend's stranded resources inside a workload account.
#
# This role exists to destroy things in an account it does not live in, which
# makes every one of its bounds load-bearing at once. The invariants under test
# are the four that separate "a bounded teardown credential" from "a cross-account
# delete-anything key":
#
#   1. Trust      — exactly one principal (portal's management-account role), and
#                   an sts:ExternalId condition. A trust that widened to a second
#                   principal, or lost the ExternalId, turns this into a
#                   confused-deputy handle: any caller who can reach the portal
#                   role's identity could tear down a workload account.
#   2. Delete-only — no destructive Allow may carry a Create/Put/Update/Modify
#                   verb. The whole audit story is "portal assumed the unwedge
#                   role, therefore a teardown happened"; a single create verb
#                   makes that sentence false and nothing else in the system
#                   notices.
#   3. Tag gate   — the broad destructive statement is conditioned on
#                   aws:ResourceTag/ProvisionedBy = eks-fleet. Without it,
#                   Resource "*" on eks:DeleteCluster reaches every cluster in the
#                   account rather than the wedged one. The failure mode of the
#                   condition being present and wrong is a stuck teardown; the
#                   failure mode of it being absent is an account-wide one.
#   4. Ceiling    — the permissions boundary is attached AND denies the escalation
#                   verbs, including altering its own boundary. A boundary that is
#                   authored but not attached is the shape this repo has found
#                   elsewhere: it reads as a control and constrains nothing.
#
# PROVIDER STRATEGY (real, credential-less) — the same one fleet-hub and
# fleet-vend use, and for the same reason. The trust is rendered by
# data.aws_iam_policy_document.unwedge_trust, and a mock_provider replaces that
# data source's json with a placeholder — so every assertion about the trust
# would pass against a fixture rather than against the policy. A real provider
# with skip_* flags renders the document locally, with no credentials and no
# network, and override_data supplies only the two API-backed data sources so the
# account-qualified ARNs resolve.
#
# The boundary and the role policy are built with jsonencode() inline, so they
# would render either way; the trust is what forces the choice.
#
# Assertions locate statements by Sid or by their actions, never by position, so
# reordering cannot mask a regression.

provider "aws" {
  region                      = "us-east-1"
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
    account_id = "222222222222"
    arn        = "arn:aws:iam::222222222222:user/test"
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
  environment     = "staging"
  region          = "us-east-1"
  team            = "platform"
  portal_role_arn = "arn:aws:iam::111111111111:role/portal-worker"
}

# INVARIANT 1 — the trust is one principal and an ExternalId, and nothing else.
#
# Asserted as an EXACT match on the principal list rather than a `contains`, which
# is the difference that matters: a `contains` check passes happily while a second
# principal sits beside the expected one.
run "trust_is_one_principal_with_an_external_id" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.unwedge.assume_role_policy).Statement :
      s if try(s.Effect, "") == "Allow"
      && try(s.Principal.AWS, null) == "arn:aws:iam::111111111111:role/portal-worker"
      && try(s.Condition.StringEquals["sts:ExternalId"], "") == "eks-fleet-unwedge"
    ]) == 1
    error_message = "the unwedge trust must name exactly the portal role and require sts:ExternalId — a widened principal or a dropped ExternalId makes this a confused-deputy handle on a cross-account delete credential"
  }

  # One statement total. A second Allow is how a trust widens without the first
  # one appearing to change.
  assert {
    condition     = length(jsondecode(aws_iam_role.unwedge.assume_role_policy).Statement) == 1
    error_message = "the unwedge trust must carry exactly one statement; a second Allow widens the trust while the original still reads correct"
  }
}

# INVARIANT 2 — delete-only. The claim in the component header is that assuming
# this role is unambiguously a teardown, and that claim is only true if no Allow
# anywhere can create or mutate.
run "role_policy_can_only_destroy" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.unwedge.policy).Statement : [
        for a in(can(tolist(s.Action)) ? tolist(s.Action) : [s.Action]) :
        !can(regex("(?i):(Create|Put|Update|Modify|Attach|Associate|Import|Register|Run|Start)", a))
        || try(s.Effect, "") == "Deny"
        # Discover is read-only; its verbs are List/Describe/Get and are covered
        # by the same rule.
      ]
    ]))
    error_message = "an Allow in the unwedge role policy carries a create/mutate verb. The component's audit story is that assuming this role means a teardown happened — one create verb makes that sentence false, and nothing else in the system would notice"
  }
}

# INVARIANT 3 — the broad destructive statement is tag-gated.
#
# This is the one that decides blast radius. eks:DeleteCluster on Resource "*"
# with no condition reaches every cluster in the account; with the tag condition
# it reaches only what the fleet provisioned.
run "destructive_actions_are_scoped_to_fleet_provisioned_resources" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.unwedge.policy).Statement :
      s if try(s.Sid, "") == "TeardownTagged"
      && try(s.Condition.StringEquals["aws:ResourceTag/ProvisionedBy"], "") == "eks-fleet"
      && contains(tolist(s.Action), "eks:DeleteCluster")
      && contains(tolist(s.Action), "ec2:DeleteVpc")
    ]) == 1
    error_message = "the broad teardown statement must be conditioned on aws:ResourceTag/ProvisionedBy = eks-fleet — without it, Resource \"*\" on eks:DeleteCluster and ec2:DeleteVpc reaches every cluster and VPC in the account rather than the wedged vend's"
  }

  # Whole-policy sweep: every Allow that names a destructive verb is either
  # tag-conditioned or pinned to a typed ARN. Resource "*" with neither is the
  # shape that turns a bounded credential into an account-wide one, and it can
  # arrive by adding a statement rather than by editing this one.
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.unwedge.policy).Statement :
      try(s.Effect, "") != "Allow"
      || !anytrue([
        for a in(can(tolist(s.Action)) ? tolist(s.Action) : [s.Action]) :
        can(regex("(?i):(Delete|Terminate|Revoke|Disassociate|Detach|Remove|ScheduleKeyDeletion|Disable)", a))
      ])
      || can(s.Condition)
      || (can(tolist(s.Resource)) ? !contains(tolist(s.Resource), "*") : try(s.Resource, "") != "*")
    ])
    error_message = "an Allow with a destructive verb has Resource \"*\" and no Condition. Every destructive grant must be tag-conditioned or pinned to a typed ARN — otherwise it reaches the whole account, and the difference is invisible in the policy's shape"
  }
}

# INVARIANT 4a — the ceiling HOLDS. (That it is ATTACHED is asserted in
# fleet-unwedge-wiring.tftest.hcl, which pins the computed ARNs with a mock
# provider; under this file's real provider those ARNs are unknown at plan and an
# equality against them proves nothing either way.)
run "boundary_denies_escalation" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.unwedge_boundary.policy).Statement :
      s if try(s.Sid, "") == "DenyEscalation"
      && try(s.Effect, "") == "Deny"
      && contains(tolist(s.Action), "organizations:*")
      && contains(tolist(s.Action), "iam:CreateUser")
      && contains(tolist(s.Action), "iam:CreateAccessKey")
      && contains(tolist(s.Action), "iam:DeleteRolePermissionsBoundary")
    ]) == 1
    error_message = "the boundary must Deny the escalation verbs — organizations:*, principal creation, access-key minting, and boundary removal. A teardown credential that can mint an identity outlives the teardown"
  }

  # The role must not be able to widen its own ceiling. This is the statement that
  # makes the boundary a boundary rather than a suggestion.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.unwedge_boundary.policy).Statement :
      s if try(s.Sid, "") == "ProtectBoundaryAndSelf"
      && try(s.Effect, "") == "Deny"
      && contains(tolist(s.Action), "iam:CreatePolicyVersion")
      && contains(tolist(s.Action), "iam:SetDefaultPolicyVersion")
      && contains(tolist(s.Action), "iam:UpdateAssumeRolePolicy")
    ]) == 1
    error_message = "the boundary must Deny the unwedge role editing its own boundary policy or its own trust — without it the ceiling is self-modifiable and therefore not a ceiling"
  }
}
