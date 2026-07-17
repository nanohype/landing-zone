---
name: plan
description: Run terragrunt plan for a specific environment and component
argument-hint: <environment> [component]
user-invocable: true
allowed-tools: Bash(make plan *), Bash(terragrunt plan *), Bash(terragrunt run-all plan *)
---

Run `make plan` for the given environment and optional component.

**Arguments:**
- `$ARGUMENTS[0]` — environment (development, staging, production, org) — required
- `$ARGUMENTS[1]` — component name (network, cluster, druid, etc.) — defaults to "all"

**Steps:**
1. Validate that the environment exists in `live/`
2. If a component is specified, validate it exists in `live/{env}/{component}/`
3. Run `make plan ENVIRONMENT=$ARGUMENTS[0] COMPONENT=$ARGUMENTS[1]`
4. Summarize the plan output — resources to add/change/destroy

If no arguments are provided, ask which environment to plan.
