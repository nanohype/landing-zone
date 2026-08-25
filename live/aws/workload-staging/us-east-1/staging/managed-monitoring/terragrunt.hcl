include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/managed-monitoring.hcl"
  merge_strategy = "deep"
}

# The AMP Alertmanager needs somewhere to send what it accepts. Its route lands on
# a single receiver, and a receiver with no destination is a valid config that
# discards every alert silently — so the topic is wired here rather than left to a
# default, and the component refuses the flag without one.
#
# It routes to the CRITICAL tier because an SLO burn-rate breach is a page. The
# observability component in this same account owns those topics; the dependency is
# account-local, which the installability rule requires.
dependency "observability" {
  config_path = "../observability"

  # The mock ARNs carry this leaf's OWN placeholder account, not a foreign one:
  # the topic really is in this account, and a foreign placeholder has no
  # injection path (scripts/check-foreign-placeholders.py).
  mock_outputs = {
    sns_topic_arns     = { critical = "arn:aws:sns:us-east-1:222222222222:mock-critical" }
    alerts_kms_key_arn = "arn:aws:kms:us-east-1:222222222222:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs_merge_strategy_with_state  = "shallow"
}

inputs = {
  amp_alert_rules_enabled = true
  amp_alert_sns_topic_arn = dependency.observability.outputs.sns_topic_arns.critical
  amp_alert_kms_key_arn   = dependency.observability.outputs.alerts_kms_key_arn
}
