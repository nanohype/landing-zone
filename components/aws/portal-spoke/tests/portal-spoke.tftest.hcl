# Unit tests for portal-spoke — the cross-account role the portal hub assumes to
# READ cluster state in a workload account.
#
# A read-only cross-account role sounds like it has little to protect, and that is
# exactly what makes its bounds worth asserting: nothing about a widened one looks
# alarming in a diff. The invariants are
#
#   1. Trust      — one principal (the portal hub role) and an sts:ExternalId. The
#                   ExternalId is the confused-deputy guard: without it, anyone who
#                   can induce the hub role to assume on their behalf reads this
#                   account's cluster inventory.
#   2. Read-only  — every Allow is a Describe/List/Get. This role is the reason the
#                   portal can be trusted with a fleet-wide view; a single mutating
#                   verb turns a read credential into a write one in an account the
#                   portal does not own.
#   3. Ceiling    — the boundary is attached, so the grant above is a floor rather
#                   than a suggestion.
#
# PROVIDER STRATEGY (real, credential-less). The trust renders from
# data.aws_iam_policy_document, which a mock_provider replaces with a placeholder —
# assertions against it would then be checking a fixture. The skip_* flags keep it
# offline; override_data supplies only the API-backed data sources.

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
  environment         = "staging"
  team                = "platform"
  portal_hub_role_arn = "arn:aws:iam::111111111111:role/portal-hub"
}

run "trust_is_one_principal_with_an_external_id" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.spoke.assume_role_policy).Statement :
      s if try(s.Effect, "") == "Allow"
      && try(s.Principal.AWS, null) == "arn:aws:iam::111111111111:role/portal-hub"
      && try(s.Condition.StringEquals["sts:ExternalId"], "") != ""
    ]) == 1
    error_message = "the spoke trust must name exactly the portal hub role and require sts:ExternalId — without the ExternalId, anyone who can induce the hub role to assume on their behalf reads this account's cluster inventory"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.spoke.assume_role_policy).Statement) == 1
    error_message = "the spoke trust must carry exactly one statement; a second Allow widens it while the first still reads correct"
  }
}

# Read-only, asserted as a property of EVERY action rather than a check on the
# three that exist today. A fourth statement added later is judged by the same
# rule without anyone remembering to extend this test.
run "role_grants_only_reads" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.spoke.policy).Statement : [
        for a in flatten([s.Action]) :
        can(regex(":(Describe|List|Get)", a))
      ]
    ]))
    error_message = "every action in the portal-spoke role policy must be a Describe/List/Get. This is a cross-account credential in an account the portal does not own; one mutating verb makes it a write credential and nothing in a diff would look alarming"
  }
}


# NOT ASSERTED HERE, and stated rather than silently absent: that the boundary is
# ATTACHED to the role, and that the published SSM parameter names this role.
#
# Both are reference-to-reference equalities against values that are UNKNOWN at
# plan under this file's real provider — `aws_iam_policy.spoke_boundary.arn` and
# `aws_iam_role.spoke.arn` are computed — and OpenTofu refuses an unknown
# comparison rather than guessing it. Two ways out were tried and neither is
# sound:
#
#   * A mock provider makes those ARNs known, but it also replaces
#     data.aws_iam_policy_document with a placeholder, which is what the trust
#     assertions above read.
#   * Splitting the two concerns across two files does not help: a file-level
#     mock_provider or override_data applies to the WHOLE `tofu test` run rather
#     than to its own file, so the mock reached this file too and the trust
#     rendered empty — this suite passed alone and failed beside its sibling,
#     which is the worst of the three outcomes.
#
# So the attachment is covered by `tofu plan` in CI rather than here. A `command =
# apply` run against a mock would make the values known and is the way to assert
# it, at the cost of this suite no longer being plan-only.
