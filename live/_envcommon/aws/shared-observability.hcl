terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/shared-observability"
}

# shared-observability is the fleet-wide alarm destination: one set of severity SNS topics
# every workload account's CloudWatch alarms publish to. No dependency block — the topics and
# their CMK authorize cross-account publishing by org membership (aws:SourceOrgID), not by
# wiring another live leaf's outputs, so nothing arrives through this repo's state.
#
# organization_id scopes that grant to this organization. Replace the placeholder with the real
# o-xxxxxxxxxx id at deploy time.
inputs = {
  team            = "sre"
  organization_id = "o-0123456789"
}
