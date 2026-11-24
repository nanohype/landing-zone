include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/org-scp.hcl"
  merge_strategy = "deep"
}

# The guardrail SCPs are authored in components/aws/org-scp/guardrails.tf, and every
# one ships attached to nothing: this repo authors the Deny policies, and an operator
# decides where they bind. Attaching an SCP is an org-wide act with no undo path for
# whoever it locks out, and the OU ids it would name are estate values a substrate
# repo does not hold.
#
# The consequence to hold onto: a created policy governs nothing. Nothing in AWS
# reports an unattached SCP as a gap, so the only signal is this file. Name the OU or
# account ids a guardrail binds to in `guardrail_targets` (keyed by the guardrail's
# name) to put it in force, and read `docs/threat-model.md` section 6 first — several
# of these deny verbs the deploy role itself uses.
inputs = {
  allowed_regions   = ["us-east-1"]
  guardrail_targets = {}
}
