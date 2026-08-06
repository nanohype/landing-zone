include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/tenant-substrate.hcl"
  merge_strategy = "deep"
}

# Generated from the Platform CRs, never edited here.
#
# The component provisions a tenant's declared stores from this map and the
# eks-agent-platform operator generates the scoped IAM from the same
# declaration, so both halves read one source: each tenant's own Platform CR.
# `tenants.selection.yaml` names the tenants this environment carries;
# `scripts/render-tenants.py` resolves each to its CR and writes
# tenants.generated.json. CI re-renders and fails on drift, so a CR that
# changes without a re-render cannot leave the declaration and the provisioned
# stores disagreeing.
#
# Read as a file rather than inlined so the diff of a substrate change is the
# rendered map itself, and so this leaf holds no datastore facts to drift from
# the CR.
#
# Environment-specific overrides land here.
inputs = {
  tenants = jsondecode(file("${get_terragrunt_dir()}/tenants.generated.json"))
}
