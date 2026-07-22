---
name: add-tenant
description: Add a new tenant to a multi-tenant component
argument-hint: <component> <tenant-name> [environment]
user-invocable: true
---

Add a new tenant to a multi-tenant component.

**Arguments:**
- `$ARGUMENTS[0]` — component (druid, pipeline, governance)
- `$ARGUMENTS[1]` — tenant name (e.g., "analytics", "ml-team")
- `$ARGUMENTS[2]` — environment (default: all environments)

Map the environment to its account (region is `us-west-2`):
development → `workload-development`, staging → `workload-staging`,
production → `workload-production`.

## Steps

1. **Validate** the component supports multi-tenancy by checking for `var.tenants` in `components/aws/$ARGUMENTS[0]/variables.tf`

2. **Read the tenant schema** from `variables.tf` to understand available options and defaults

3. **Show the user** the available tenant configuration options with their defaults

4. **Ask** which options they want to customize (or accept all defaults)

5. **Add the tenant** to the `tenants` map in `live/aws/<account>/us-west-2/<env>/$ARGUMENTS[0]/terragrunt.hcl`'s `inputs` block. If `$ARGUMENTS[2]` is provided, only add to that environment — otherwise add to all three (development, staging, production)

6. **Show a plan preview**: suggest running `/plan {env} $ARGUMENTS[0]` to see what will be created
