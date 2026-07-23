terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/model-import"
}

# model-import is account+region-scoped and cluster-independent: no dependency on
# the cluster or the secrets CMK. The imported-model artifacts it stages outlive
# any single cluster, so the substrate does too. Region + environment come from
# the root config; only the owning team is set here.
inputs = {
  team = "platform"
}
