---
name: add-component
description: Scaffold a new infrastructure component with all required files
argument-hint: <component-name>
user-invocable: true
allowed-tools: Bash(task check), Bash(task validate), Bash(task gates)
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

4. **Document the component** in `docs/architecture.md`. Add a row to the
   component table for its layer under `## Layer Breakdown`, and name the
   component in the layer list in `CLAUDE.md`.

   This is not optional polish: `scripts/check-architecture-components.sh` fails
   the build for any component under `components/aws/` that no table in
   `docs/architecture.md` names, and for any the `CLAUDE.md` list omits. Both
   directions are gated, so a component scaffolded and committed without its row
   fails CI on its first PR.

5. **Declare the teardown posture.** `scripts/check-teardown-gates.py` requires
   one of two things from any component holding an `aws_s3_bucket`,
   `aws_rds_cluster`, `aws_dynamodb_table` or `aws_secretsmanager_secret`:

   - a `force_destroy_buckets` variable wired so that every teardown-gate
     attribute the resource types need (`force_destroy`, `skip_final_snapshot`,
     `final_snapshot_identifier`, `deletion_protection`,
     `deletion_protection_enabled`, `recovery_window_in_days`) resolves
     permissively when the lever is set, or
   - an entry in that script's `EXEMPT` table stating why the component has no
     lever.

   A partially-gated component is the failure this prevents: it empties its data
   and then wedges on whatever it still protects.

6. **Write the test suite** at `components/aws/$ARGUMENTS/tests/$ARGUMENTS.tftest.hcl`.
   Every other root carries one, running at `command = plan` against a
   `mock_provider` so it needs no credentials or network. Assert what the
   component itself composes — its names, its policy statements, its
   variable validations — and locate policy statements by `Sid` rather than by
   position so reordering cannot mask a regression.

7. **Run the gates**: `task check` — formatting, validation, lint, the `tofu test`
   suites, and every script under `scripts/`. This is what CI runs.

8. **Show next steps**: no workflow edit is needed. The `ci.yml` validate, test
   and plan matrices are auto-discovered from the tree via `git ls-files`, so the
   new component's jobs materialize once its files are committed.
