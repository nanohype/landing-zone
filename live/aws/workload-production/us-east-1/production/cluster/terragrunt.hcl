include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/cluster.hcl"
  merge_strategy = "deep"
}

inputs = {
  system_node_min_size     = 3
  system_node_max_size     = 9
  system_node_desired_size = 3
  system_node_disk_size    = 100
}
