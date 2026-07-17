---
name: destroy
description: Safely destroy infrastructure for a non-production environment
argument-hint: <environment> <component>
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash(terragrunt plan -destroy*), Bash(task destroy *)
---

Safely destroy infrastructure. Production is never allowed.

**Arguments:**
- `$ARGUMENTS[0]` — environment (development or staging ONLY)
- `$ARGUMENTS[1]` — component name

Map the environment to its account (region is `us-west-2`):
development → `workload-development`, staging → `workload-staging`.

## Steps

1. **Block production**: If environment is "production", refuse immediately

2. **Validate** the environment and component exist at `live/aws/<account>/us-west-2/$ARGUMENTS[0]/$ARGUMENTS[1]/`

3. **Show what will be destroyed**: run `terragrunt plan -destroy` in `live/aws/<account>/us-west-2/$ARGUMENTS[0]/$ARGUMENTS[1]/` and summarize the resources

4. **Check dependencies**: read `live/_envcommon/aws/$ARGUMENTS[1].hcl` — warn if other components depend on this one (e.g., destroying network when cluster exists)

5. **Require explicit confirmation** from the user before proceeding

6. Only after confirmation, run `task destroy ACCOUNT=<account> REGION=us-west-2 ENVIRONMENT=$ARGUMENTS[0] COMPONENT=$ARGUMENTS[1]`
