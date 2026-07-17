---
name: destroy
description: Safely destroy infrastructure for a non-production environment
argument-hint: <environment> <component>
user-invocable: true
disable-model-invocation: true
---

Safely destroy infrastructure. Production is never allowed.

**Arguments:**
- `$ARGUMENTS[0]` — environment (development or staging ONLY)
- `$ARGUMENTS[1]` — component name

## Steps

1. **Block production**: If environment is "production", refuse immediately

2. **Validate** the environment and component exist

3. **Show what will be destroyed**: Run `terragrunt plan -destroy` in `live/$ARGUMENTS[0]/$ARGUMENTS[1]/` and summarize the resources

4. **Check dependencies**: Read `live/_envcommon/$ARGUMENTS[1].hcl` — warn if other components depend on this one (e.g., destroying network when cluster exists)

5. **Require explicit confirmation** from the user before proceeding

6. Only after confirmation, run `terragrunt destroy` in the component directory
