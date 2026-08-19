include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/tenant-substrate.hcl"
  merge_strategy = "deep"
}

# Empty, and nothing renders it yet.
#
# The component provisions a tenant's declared stores from this map, and the
# eks-agent-platform operator generates the scoped IAM from the same
# declaration. What does not exist is the step between: nothing carries a
# Platform CR's spec.datastores into this input. So a tenant that declares
# datastores gets none, in any environment, and the failure is silence — the
# apply succeeds with nothing to do.
#
# Until that renderer lands, a map written by hand here is the only way a
# tenant gets a datastore, and it will be overwritten when one does. Building
# it is tracked work; the guardrails that used to describe it as already
# happening (nanohype/standards/platform-tenant-contract.json, fab's
# FACTORY_PREAMBLE) now say so.
#
# Environment-specific overrides land here.
inputs = {
  tenants = {}
}
