include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/shared-backup.hcl"
  merge_strategy = "deep"
}

# The production central vault. Recovery points must survive a full week before any override
# can remove them, so the governance lock floor is raised to 7 days here.
inputs = {
  min_retention_days = 7
}
