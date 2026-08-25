include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/shared-observability.hcl"
  merge_strategy = "deep"
}

# The fleet-wide alarm topics, and the on-call address(es) they page.
#
# A workload cluster reaches these topics by opting in: its observability leaf sets
# `observability_mode = "adopt"` and passes this component's `sns_topic_arns` output
# as `adopt_topic_arns`. No leaf in this tree does, so every workload cluster runs
# the `create` default and builds its own private topics — these are created and
# have no publishers until an operator opts a cluster in.
#
# The ARNs cross an account boundary, so they are supplied as literal inputs on the
# consuming leaf rather than through a terragrunt `dependency`: a dependency on
# another account's state fails at config-parse time (see `docs/inputs.md`, and the
# gate at `scripts/check-account-local-deps.py`).
#
# `alert_email_endpoints` is empty for the same reason `target_ids` is empty in
# org-scp — an on-call address is an estate value, not a product default. A topic
# set with no subscription delivers nowhere, and nothing in AWS reports that.
inputs = {
  alert_email_endpoints = []
}
