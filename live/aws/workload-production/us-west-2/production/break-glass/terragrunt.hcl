include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/break-glass.hcl"
  merge_strategy = "deep"
}

inputs = {
  # The account allowed to assume this AdministratorAccess role in an emergency.
  #
  # 123456789012 is the placeholder for "the management account has not been
  # provisioned", and it must not stay here: a break-glass role whose only
  # trusted principal is an account outside this organization is assumable by
  # nobody, and it reads as configured. That is the worst possible state for the
  # one control whose entire purpose is to work when everything else does not.
  #
  # Left EMPTY deliberately rather than defaulted to this account. Trusting your
  # own account root is not break-glass — the point is to survive this account's
  # IAM being compromised or misconfigured, which a principal inside it cannot
  # do. The component refuses an empty list, so applying this leaf is blocked
  # until a real trusted account exists, which is the honest state today.
  #
  # rackctl never applies this leaf (internal/phases/singletons_test.go asserts
  # it): a teardown that removes the account's emergency access path removes the
  # thing you would use to fix the teardown.
  trusted_account_ids  = []
  max_session_duration = 3600
}
