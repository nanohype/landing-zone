terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/org-compliance"
}

inputs = {
  team = "platform"
}
