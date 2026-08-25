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
# The selection is empty here — no tenant is promoted to this environment yet —
# so the rendered map is empty and the component provisions nothing. Adding a
# name to the selection file is the whole act.
#
# Environment-specific overrides land here.
inputs = {
  tenants = {}
}
