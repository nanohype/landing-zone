# Contributing

Guide for developing and extending the landing-zone infrastructure.

## Prerequisites

Complete the [Onboarding Guide](docs/onboarding.md) first -- tool installation, cloud access, and codebase orientation.

## Development Workflow

1. **Branch** -- create a feature branch from `main`
2. **Validate locally** -- `task fmt:check && task validate CLOUD=<cloud> && task lint CLOUD=<cloud>`
3. **Plan against dev** -- `task plan CLOUD=<cloud> ACCOUNT=workload-dev REGION=<region> ENVIRONMENT=dev COMPONENT=<name>`
4. **Open a PR** -- CI runs fmt, validate (per cloud/component matrix), tflint (per cloud), checkov, and plan matrix
5. **Review** -- get approval, verify plan output in CI
6. **Merge** -- deploy via `deploy.yml` workflow dispatch

## Adding a New Component

1. Create `components/{cloud}/{name}/` with these files:
   - `main.tf` -- primary resources
   - `variables.tf` -- inputs (all must have `description`, enforced by tflint)
   - `outputs.tf` -- outputs (all must have `description`, enforced by tflint)
   - `versions.tf` -- `required_version` and `required_providers`

2. Use snake_case for all resource names and variables (enforced by tflint `terraform_naming_convention`).

3. Do **not** add default tags/labels (`Environment`, `ManagedBy`, `Project`, etc.) -- they are injected by the root `terragrunt.hcl`.

4. Cloud-specific conventions:

   | Cloud | Convention |
   |-------|-----------|
   | AWS | Use `default_tags` (injected by provider). Resource names: `{project}-{env}-{component}-{resource}`. |
   | GCP | Use `default_labels` (injected by provider). Labels must be lowercase with underscores -- the root config handles this. Resource names must comply with GCP's 63-character limit. |
   | Azure | Tags applied per-component. Resources must be placed in a resource group. Use `azurerm_resource_group` data source or create one per component. |

5. Create `live/_envcommon/{cloud}/{name}.hcl` with:
   - `terraform` block pointing to `components/{cloud}/{name}/`
   - `dependency` blocks for any upstream components
   - `inputs` block wiring dependency outputs to variables

6. Create `live/{cloud}/{account}/{region}/{env}/{name}/terragrunt.hcl` for each target environment:
   ```hcl
   include "root" {
     path = find_in_parent_folders()
   }

   include "envcommon" {
     path   = "${dirname(find_in_parent_folders())}/_envcommon/{cloud}/{name}.hcl"
     expose = true
   }

   inputs = {
     # environment-specific overrides here
   }
   ```

7. Add the component to CI workflow matrices:
   - `ci.yml` -- add to the validate and plan matrices for the appropriate cloud
   - `deploy.yml` -- add to the component allowlist
   - `destroy.yml` -- add to the component allowlist

8. Update `README.md` -- add a row to the Components Reference table.

## Adding a Multi-Tenant Component (AWS only)

Follow the standard component steps above, plus:

1. Create `components/aws/{name}/modules/tenant/` sub-module with its own `variables.tf` and `outputs.tf`.

2. Define a `tenants` variable in the root module:
   ```hcl
   variable "tenants" {
     description = "Map of tenant configurations"
     type = map(object({
       # tenant-specific fields with defaults
     }))
     default = {}
   }
   ```

3. Instantiate the tenant module with `for_each`:
   ```hcl
   module "tenant" {
     source   = "./modules/tenant"
     for_each = var.tenants
     name     = each.key
     # pass each.value fields
   }
   ```

4. Use the shared workload identity module (`modules/aws/workload-identity/`) for pod IAM roles.

Existing multi-tenant components to reference: `druid`, `pipeline`, `gateway`, `llm`, `mlops`, `rag`, `governance`.

## Adding a Tenant

Edit the environment's `terragrunt.hcl` for the component and add an entry to the `tenants` map:

```hcl
# live/aws/workload-staging/us-west-2/staging/druid/terragrunt.hcl
inputs = {
  tenants = {
    existing-tenant = { ... }
    new-tenant = {
      rds_min_acu = 0.5
      rds_max_acu = 8
      msk_enabled = true
    }
  }
}
```

Each component's `variables.tf` documents the full tenant schema with defaults.

## Adding a New Environment

1. Copy an existing environment directory: `cp -r live/{cloud}/{account}/{region}/dev/ live/{cloud}/{account}/{region}/<env>/`
2. Update the new `env.hcl` with the environment name and any changed metadata
3. If targeting a new account/project/subscription, create the corresponding `account.hcl`
4. Adjust component inputs (node counts, feature toggles, etc.)
5. Add the environment to `deploy.yml` and optionally `destroy.yml` dispatch inputs
6. Create the state backend: `./scripts/init-backend-{cloud}.sh`

## Adding a New Cloud Region

1. Create the region directory: `live/{cloud}/{account}/{new-region}/`
2. Add a `region.hcl` with the region identifier
3. Copy environment directories from an existing region and adjust inputs
4. Create the state backend in the new region: `./scripts/init-backend-{cloud}.sh`

## Code Style

- **OpenTofu, not Terraform** -- use `tofu` CLI, never `terraform`
- **Formatting** -- `tofu fmt` style (2-space indent, aligned `=`)
- **Documentation** -- all variables and outputs must have `description`
- **Naming** -- snake_case everywhere
- **Tags/Labels** -- never duplicate default tags/labels in components
- **Dependencies** -- wiring goes in `live/_envcommon/{cloud}/`, not in the component
- **State** -- one state file per component per environment, cloud-native backend with native locking
- **Components** -- always under `components/{cloud}/{name}/`, never at the top level
