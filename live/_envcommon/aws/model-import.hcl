terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/model-import"
}

# model-import is environment+account+region-scoped and cluster-independent: no
# dependency on the cluster or the secrets CMK, because the staging bucket and the
# import role are shared by every cluster in the environment. The imported model
# is not held here at all — Bedrock stores and manages it — so this substrate can
# be torn down with its environment without affecting a model already in service.
# Region + environment come from the root config; only the owning team is set here.
inputs = {
  team = "platform"
}
