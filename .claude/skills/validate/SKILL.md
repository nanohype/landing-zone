---
name: validate
description: Run the full validation suite (fmt-check, validate, lint)
user-invocable: true
allowed-tools: Bash(task *)
---

Run the full validation suite in order:

1. `task fmt:check` — verify formatting
2. `task validate` — init + validate every component, fleet vend root, and shared module
3. `task lint` — tflint with the AWS plugin (hard gate at `notice` severity)

Report results for each step. If any step fails, show the error and suggest a fix.
If formatting fails, offer to run `task fmt` to auto-fix.
