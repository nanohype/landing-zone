# landing-zone

Multi-cloud OpenTofu + Terragrunt monorepo for enterprise platform infrastructure (AWS, GCP, Azure).

## Build & Validate

```bash
make fmt                                              # format all .tf files
make fmt-check                                        # check formatting (CI uses this)
make validate CLOUD=aws                               # init + validate every AWS component
make validate CLOUD=gcp                               # init + validate every GCP component
make validate CLOUD=azure                             # init + validate every Azure component
make lint CLOUD=aws                                   # tflint with AWS plugin
make lint CLOUD=gcp                                   # tflint with GCP plugin
make lint CLOUD=azure                                 # tflint with Azure plugin
make plan CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=network
make apply CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev
```

## Architecture

- **24 AWS components**, **17 GCP components**, **17 Azure components** across 3 clouds
- **4 environments** per cloud: dev, staging, production, org (AWS management account)
- **Multi-account isolation:** workload-dev, workload-staging, workload-prod, management (AWS)
- **Multi-region support:** us-west-2 (AWS), us-central1 (GCP), westus2 (Azure)
- **Dependency chain:** `network → cluster → {druid, pipeline, llm, gateway, rag, mlops, governance, observability, secrets, cluster-addons, cluster-bootstrap}`
- `cost`, `dns`, `backup`, `break-glass`, and `service-quotas` are standalone (no dependencies)
- `org-*` components deploy to management/org accounts only
- **GitOps boundary:** OpenTofu deploys cloud resources + Cilium + ArgoCD. ArgoCD manages in-cluster workloads via [eks-gitops](https://github.com/nanohype/eks-gitops)

## Conventions

- OpenTofu >= 1.11.0, not Terraform — use `tofu` CLI, never `terraform`
- All HCL files: `tofu fmt` style (2-space indent, aligned `=`)
- Component variables must have descriptions (enforced by tflint `terraform_documented_variables`)
- Component outputs must have descriptions (enforced by tflint `terraform_documented_outputs`)
- Snake_case for all resource names and variables (enforced by tflint `terraform_naming_convention`)
- Default tags/labels (Environment, ManagedBy, Project) are injected by root terragrunt.hcl — do not duplicate in components
- Every component lives in `components/{cloud}/{name}/` with its own `versions.tf`
- Dependency wiring lives in `live/_envcommon/{cloud}/{name}.hcl`, not in the component itself
- Environment-specific overrides go in `live/{cloud}/{account}/{region}/{env}/{component}/terragrunt.hcl`
- State paths:
  - AWS: `s3://{account_id}-{region}-tfstate/{env}/{component}/terraform.tfstate` (native S3 locking)
  - GCP: `gs://{project_id}-{region}-tfstate/{env}/{component}/`
  - Azure: `tfstate-rg/{storage_account}/tfstate/{env}/{component}/terraform.tfstate`

## Multi-Tenant Pattern (AWS only)

7 components use `var.tenants = map(object({...}))` with `for_each`:
druid, pipeline, gateway, llm, mlops, rag, governance.

Each tenant gets isolated AWS resources (databases, buckets, queues, IRSA roles).
Tenant modules live in `components/aws/{name}/modules/tenant/`.

## File Structure

```
components/
  aws/                     # 24 AWS OpenTofu root modules
    {name}/
      main.tf
      variables.tf
      outputs.tf
      versions.tf
      modules/tenant/      # sub-module for multi-tenant components
  gcp/                     # 17 GCP OpenTofu root modules
    {name}/
  azure/                   # 17 Azure OpenTofu root modules
    {name}/
modules/
  aws/workload-identity/   # AWS IRSA role factory
  gcp/workload-identity/   # GKE Workload Identity binding
  azure/workload-identity/ # AKS federated credential
live/
  terragrunt.hcl           # root config (multi-cloud provider dispatch + state backend)
  _envcommon/
    aws/{name}.hcl         # AWS dependency wiring + shared inputs
    gcp/{name}.hcl         # GCP dependency wiring
    azure/{name}.hcl       # Azure dependency wiring
  aws/
    cloud.hcl              # cloud = "aws"
    {account}/
      account.hcl          # account_id, account_alias
      {region}/
        region.hcl         # region
        {env}/
          env.hcl          # environment, cost_center, business_unit, etc.
          {component}/terragrunt.hcl
  gcp/
    cloud.hcl              # cloud = "gcp"
    {account}/
      account.hcl          # project_id, account_alias
      {region}/
        region.hcl
        {env}/
          env.hcl
          {component}/terragrunt.hcl
  azure/
    cloud.hcl              # cloud = "azure"
    {account}/
      account.hcl          # subscription_id, tenant_id, account_alias
      {region}/
        region.hcl
        {env}/
          env.hcl
          {component}/terragrunt.hcl
```

## Testing Changes

1. `make fmt-check` — formatting
2. `make validate CLOUD=aws` — syntax + provider validation
3. `make lint CLOUD=aws` — tflint rules
4. `make plan CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=<name>` — dry-run against dev

## CI/CD

- `ci.yml` — PRs: fmt, validate (per cloud/component matrix), tflint (per cloud), checkov, plan matrix
- `deploy.yml` — manual dispatch: cloud/account/region/environment/component, plan or apply
- `destroy.yml` — manual dispatch: dev/staging only, requires confirmation string
- `drift.yml` — scheduled weekday drift detection on production, creates GitHub issues
- Auth: AWS OIDC, GCP Workload Identity Federation, Azure Federated Identity (conditional per cloud)
