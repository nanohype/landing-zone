---
name: add-component
description: Scaffold a new infrastructure component with all required files
argument-hint: <component-name>
user-invocable: true
allowed-tools: Bash(task validate)
---

Scaffold a new component named `$ARGUMENTS`.

## Steps

1. **Create the component module** in `components/aws/$ARGUMENTS/`:
   - `main.tf` — primary resources (empty template with a `locals` block)
   - `variables.tf` — documented inputs. Declare the uniform envcommon interface
     inputs (`region`, `environment`, `vpc_id`, `cluster_sg_id`, `cluster_name`)
     so `_envcommon` can wire them uniformly; any the component doesn't consume
     still gets declared with an inline `# tflint-ignore: terraform_unused_declarations`
     + rationale.
   - `outputs.tf` — documented outputs (empty template to start)
   - `versions.tf` — matching every existing component:
     ```hcl
     terraform {
       required_version = ">= 1.11.0"
       required_providers {
         aws = {
           source  = "hashicorp/aws"
           version = "~> 6.0"
         }
       }
     }
     ```

2. **Create the envcommon config** at `live/_envcommon/aws/$ARGUMENTS.hcl`:
   - Ask which components this depends on (network, cluster, or none)
   - Wire up `dependency` blocks with `mock_outputs` restricted to
     `["validate", "plan"]`, keyed on the target component's real output names
   - Set the `terraform.source` to the component:
     `"${dirname(find_in_parent_folders("cloud.hcl"))}/../../components/aws/$ARGUMENTS"`
   - Add an `inputs` block passing dependency outputs

3. **Create environment directories** for each target environment
   (`live/aws/<account>/<region>/<env>/$ARGUMENTS/terragrunt.hcl`):
   ```hcl
   include "root" {
     path = find_in_parent_folders("root.hcl")
   }
   include "envcommon" {
     path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/$ARGUMENTS.hcl"
     merge_strategy = "deep"
   }
   inputs = {}
   ```

4. **Run validation**: `task validate` to confirm the new component initializes correctly

5. **Show next steps**: none for CI — the `ci.yml` validate and plan matrices are
   auto-discovered from the tree via `git ls-files`, so the new component's checks
   materialize once its files are committed. No workflow edit is needed.
