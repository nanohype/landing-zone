terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/github-oidc"
}

inputs = {
  team = "platform"
}
