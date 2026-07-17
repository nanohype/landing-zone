# landing-zone

OpenTofu + Terragrunt monorepo for enterprise platform infrastructure on AWS.

## Build & Validate

```bash
task fmt                                              # format all .tf files
task fmt:check                                        # check formatting (CI uses this)
task validate                                         # init + validate every component
task lint                                             # tflint with AWS plugin
task plan ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=network
task apply ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development
```

## Architecture

- **AWS components** under `components/aws/`
- **Environments:** development, staging, production, org (management account)
- **Multi-account isolation:** workload-development, workload-staging, workload-production, management
- **Multi-region support:** us-west-2
- **Dependency chain:** `network → cluster → {druid, pipeline, llm, gateway, rag, mlops, governance, observability, secrets, cluster-addons, cluster-bootstrap}`
- `cost`, `dns`, `backup`, `break-glass`, and `service-quotas` are standalone (no dependencies)
- `org-*` components deploy to the management account only
- **GitOps boundary:** OpenTofu deploys cloud resources + Cilium + ArgoCD. ArgoCD manages in-cluster workloads via [eks-gitops](https://github.com/nanohype/eks-gitops)

## Conventions

- OpenTofu >= 1.11.0, not Terraform — use `tofu` CLI, never `terraform`
- All HCL files: `tofu fmt` style (2-space indent, aligned `=`)
- Component variables must have descriptions (enforced by tflint `terraform_documented_variables`)
- Component outputs must have descriptions (enforced by tflint `terraform_documented_outputs`)
- Snake_case for all resource names and variables (enforced by tflint `terraform_naming_convention`)
- Default tags (Environment, ManagedBy, Project) are injected by the root config (`live/root.hcl`) — do not duplicate in components
- Every component lives in `components/aws/{name}/` with its own `versions.tf`
- Dependency wiring lives in `live/_envcommon/aws/{name}.hcl`, not in the component itself
- Because of that, every component declares the same interface inputs (`region`, `environment`, `vpc_id`, `cluster_sg_id`, `cluster_name`) so envcommon can wire them uniformly. A component that doesn't consume one still declares it, tagged with an inline `# tflint-ignore: terraform_unused_declarations` + rationale. Any *other* unused variable/local/data source is dead code — remove it, don't suppress it (`task lint` gates this at `notice`)
- Environment-specific overrides go in `live/aws/{account}/{region}/{env}/{component}/terragrunt.hcl`
- State path: `s3://{account_id}-{region}-tfstate/{env}/{component}/terraform.tfstate` (native S3 locking)

## Multi-Tenant Pattern

The multi-tenant components use `var.tenants = map(object({...}))` with `for_each`:
druid, pipeline, gateway, llm, mlops, rag, governance.

Each tenant gets isolated AWS resources (databases, buckets, queues, IRSA roles).
Tenant modules live in `components/aws/{name}/modules/tenant/`.

## File Structure

```
components/
  aws/                     # AWS OpenTofu root modules
    {name}/
      main.tf
      variables.tf
      outputs.tf
      versions.tf
      modules/tenant/      # sub-module for multi-tenant components
modules/
  aws/workload-identity/   # EKS Pod Identity role factory
live/
  root.hcl                 # root config (AWS provider + S3 state backend)
  _envcommon/
    aws/{name}.hcl         # dependency wiring + shared inputs
  aws/
    cloud.hcl              # anchor for component source resolution
    {account}/
      account.hcl          # account_id, account_alias
      {region}/
        region.hcl         # region
        {env}/
          env.hcl          # environment, cost_center, business_unit, etc.
          {component}/terragrunt.hcl
```

## Testing Changes

1. `task fmt:check` — formatting
2. `task validate` — syntax + provider validation
3. `task lint` — tflint rules
4. `task plan ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=<name>` — dry-run against development

## CI/CD

- `ci.yml` — PRs: fmt, validate (per-component matrix), tflint, checkov, plan matrix
- `deploy.yml` — manual dispatch: account/region/environment/component, plan or apply
- `destroy.yml` — manual dispatch: development/staging only, requires confirmation string
- `drift.yml` — scheduled weekday drift detection on production, creates GitHub issues
- Auth: AWS OIDC (`AWS_ROLE_ARN` repo variable)
