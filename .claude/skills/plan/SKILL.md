---
name: plan
description: Run terragrunt plan for a specific environment and component
argument-hint: <environment> [component]
user-invocable: true
allowed-tools: Bash(task plan *)
---

Run `task plan` for the given environment and optional component.

**Arguments:**
- `$ARGUMENTS[0]` — environment (development, staging, production, org) — required
- `$ARGUMENTS[1]` — component name (network, cluster, druid, etc.) — defaults to "all"

`task plan` needs the account and region too. Map the environment to its account
(region defaults to `us-west-2`):

| environment | account (`ACCOUNT`) |
|---|---|
| development | `workload-development` |
| staging | `workload-staging` |
| production | `workload-production` |
| org | `management` |

**Steps:**
1. Validate that the environment exists under `live/aws/<account>/us-west-2/<env>/`
2. If a component is specified, validate it exists at `live/aws/<account>/us-west-2/<env>/<component>/`
3. Run `task plan ACCOUNT=<account> REGION=us-west-2 ENVIRONMENT=$ARGUMENTS[0] COMPONENT=$ARGUMENTS[1]`
4. Summarize the plan output — resources to add/change/destroy

If no arguments are provided, ask which environment to plan.
