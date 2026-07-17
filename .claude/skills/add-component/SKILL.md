---
name: add-component
description: Scaffold a new infrastructure component with all required files
argument-hint: <component-name>
user-invocable: true
---

Scaffold a new component named `$ARGUMENTS`.

## Steps

1. **Create the component module** in `components/$ARGUMENTS/`:
   - `main.tf` — primary resources (empty template with locals block)
   - `variables.tf` — with `environment`, `region` variables (documented)
   - `outputs.tf` — empty template
   - `versions.tf` — matching existing components:
     ```hcl
     terraform {
       required_version = ">= 1.8.0"
       required_providers {
         aws = {
           source  = "hashicorp/aws"
           version = "~> 5.0"
         }
       }
     }
     ```

2. **Create the envcommon config** at `live/_envcommon/$ARGUMENTS.hcl`:
   - Ask which components this depends on (network, cluster, or none)
   - Wire up dependency blocks with mock_outputs
   - Set `terraform { source = "${path_in_repo}/components/$ARGUMENTS" }`
   - Add inputs block passing dependency outputs

3. **Create environment directories** for each of development, staging, production:
   - `live/{env}/$ARGUMENTS/terragrunt.hcl` with:
     ```hcl
     include "root" {
       path = find_in_parent_folders("terragrunt.hcl")
     }
     include "envcommon" {
       path = "${dirname(find_in_parent_folders("terragrunt.hcl"))}/_envcommon/$ARGUMENTS.hcl"
     }
     inputs = {}
     ```

4. **Run validation**: `make validate` to confirm the new component initializes correctly

5. **Show next steps**: what to add to CI matrices if needed
