terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/break-glass"
}

inputs = {
  team = "security"
}
