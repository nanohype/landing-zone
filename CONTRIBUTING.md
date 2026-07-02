# Contributing

Guide for developing and extending the landing-zone infrastructure.

## Prerequisites

Complete the [Onboarding Guide](docs/onboarding.md) first -- tool installation, cloud access, and codebase orientation.

## Development Workflow

1. **Branch** -- create a feature branch from `main`
2. **Validate locally** -- `task fmt:check && task validate && task lint`
3. **Plan against dev** -- `task plan ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=<name>`
4. **Open a PR** -- CI runs fmt, validate (per-component matrix), tflint, checkov, and the plan matrix
5. **Review** -- get approval, verify plan output in CI
6. **Merge** -- deploy via `deploy.yml` workflow dispatch

## Adding a New Component

1. Create `components/aws/{name}/` with these files:
   - `main.tf` -- primary resources
   - `variables.tf` -- inputs (all must have `description`, enforced by tflint)
   - `outputs.tf` -- outputs (all must have `description`, enforced by tflint)
   - `versions.tf` -- `required_version` and `required_providers`

2. Use snake_case for all resource names and variables (enforced by tflint `terraform_naming_convention`).

3. Do **not** add default tags/labels (`Environment`, `ManagedBy`, `Project`, etc.) -- they are injected by the root `terragrunt.hcl`.

4. Naming: resource names follow `{project}-{env}-{component}-{resource}`. Default tags come from the provider's `default_tags` (injected by the root config).

5. Create `live/_envcommon/aws/{name}.hcl` with:
   - `terraform` block pointing to `components/aws/{name}/`
   - `dependency` blocks for any upstream components
   - `inputs` block wiring dependency outputs to variables

6. Create `live/aws/{account}/{region}/{env}/{name}/terragrunt.hcl` for each target environment:
   ```hcl
   include "root" {
     path = find_in_parent_folders()
   }

   include "envcommon" {
     path   = "${dirname(find_in_parent_folders())}/_envcommon/aws/{name}.hcl"
     expose = true
   }

   inputs = {
     # environment-specific overrides here
   }
   ```

7. CI auto-discovers the new component from the tree (`git ls-files`) -- the validate and plan matrix entries materialize on the next PR with no workflow edit.

## Adding a Multi-Tenant Component

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

1. Copy an existing environment directory: `cp -r live/aws/{account}/{region}/dev/ live/aws/{account}/{region}/<env>/`
2. Update the new `env.hcl` with the environment name and any changed metadata
3. If targeting a new account, create the corresponding `account.hcl`
4. Adjust component inputs (node counts, feature toggles, etc.)
5. Add the environment to `deploy.yml` and optionally `destroy.yml` dispatch inputs
6. Create the state backend: `./scripts/init-backend-aws.sh`

## Adding a New Region

1. Create the region directory: `live/aws/{account}/{new-region}/`
2. Add a `region.hcl` with the region identifier
3. Copy environment directories from an existing region and adjust inputs
4. Create the state backend in the new region: `./scripts/init-backend-aws.sh`

## Code Style

- **OpenTofu, not Terraform** -- use `tofu` CLI, never `terraform`
- **Formatting** -- `tofu fmt` style (2-space indent, aligned `=`)
- **Documentation** -- all variables and outputs must have `description`
- **Naming** -- snake_case everywhere
- **Tags** -- never duplicate default tags in components
- **Dependencies** -- wiring goes in `live/_envcommon/aws/`, not in the component
- **State** -- one state file per component per environment, S3 backend with native locking
- **Components** -- always under `components/aws/{name}/`, never at the top level
