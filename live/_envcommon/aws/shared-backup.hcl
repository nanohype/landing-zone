terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/shared-backup"
}

# shared-backup is the owner side of central backup: a dedicated backup account runs one
# central vault per environment in the DR region, and every workload account's backup
# component copies its recovery points into it. No dependency block — the vault authorizes
# cross-account copy by org membership (aws:PrincipalOrgID), not by wiring another live
# leaf's outputs, so nothing arrives through this repo's state.
#
# organization_id scopes both the vault access policy and the vault CMK policy to this
# organization. Replace the placeholder with the real o-xxxxxxxxxx id at deploy time.
inputs = {
  team            = "sre"
  organization_id = "o-0123456789"
}
