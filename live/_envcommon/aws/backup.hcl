terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/backup"
}

inputs = {
  team = "sre"
}
