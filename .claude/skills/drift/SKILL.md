---
name: drift
description: Check for configuration drift by running plan and analyzing differences
argument-hint: <environment> [component]
user-invocable: true
allowed-tools: Bash(task plan *)
---

Check for infrastructure drift by running plan and analyzing the output.

**Arguments:**
- `$ARGUMENTS[0]` — environment (development, staging, production)
- `$ARGUMENTS[1]` — component (optional, defaults to all)

`task plan` needs the account and region. Map the environment to its account
(region defaults to `us-west-2`):

| environment | account (`ACCOUNT`) |
|---|---|
| development | `workload-development` |
| staging | `workload-staging` |
| production | `workload-production` |

## Steps

1. Run `task plan ACCOUNT=<account> REGION=us-west-2 ENVIRONMENT=$ARGUMENTS[0] COMPONENT=$ARGUMENTS[1]`, capturing the output
2. Parse the plan output for any changes (add/change/destroy)
3. If no changes: report "No drift detected"
4. If changes found: categorize them:
   - **Expected drift** — resources that are managed outside OpenTofu (e.g., auto-scaling changes)
   - **Unexpected drift** — manual changes or external modifications
   - **Destructive changes** — anything that would destroy resources
5. Summarize findings in a table: component, resource, action, details
