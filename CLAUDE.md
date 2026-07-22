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

- **AWS components** under `components/aws/`, grouped by layer:
  - **Network** — `network` (mode-aware VPC: `create` owns a VPC, `adopt` participates in a shared one), `shared-network` (owner side of the cross-account adopt topology, RAM-shares subnets), `egress-network` (central egress hub behind the org transit gateway)
  - **Cluster** — `cluster`, `cluster-bootstrap`, `cluster-addons`
  - **Workload (multi-tenant, `var.tenants`)** — `druid`, `pipeline`, `governance`
  - **Operational** — `observability`, `secrets`, `backup`, `break-glass`, `service-quotas`, `cost`, `dns`, `github-oidc`, `managed-monitoring`
  - **Agent-platform** — `agent-iam` (operator role + tenant permissions boundary + model-artifacts/eval-reports buckets) and the four per-app single-tenant substrates `competitive-intelligence-platform`, `digest-pipeline-platform`, `incident-response-platform`, `slack-knowledge-bot-platform`
  - **Fleet & portal (cross-account, hub-side)** — `fleet-hub`, `fleet-vend`, `fleet-unwedge`, `portal-hub`, `portal-spoke`
  - **Organization (management account)** — `org-identity`, `org-security`, `org-compliance`, `org-cost`, `org-networking`, `org-scp`
- **Shared modules** under `modules/aws/` — `workload-identity` (EKS Pod Identity role factory), `platform-app` (shared Pod-Identity association + `<env>-<app>-app-access` policy shell), `eks-vpc-endpoints` (the private endpoint set both create-mode `network` and `shared-network` build)
- **Environments:** development, staging, production; `hub` (fleet/portal control plane); `org` (management account)
- **Accounts:** workload-development, workload-staging, workload-production, management, `fleet` (hub control plane), `network` (network-owner account for the shared-network/egress-network adopt topology)
- **Multi-region support:** us-west-2
- **Dependency chain:** `network → cluster → {cluster-addons, cluster-bootstrap, druid, pipeline, governance, observability, secrets, agent-iam → *-platform}`
- Standalone (no dependencies): `cost`, `dns`, `backup`, `break-glass`, `service-quotas`, `github-oidc`
- `shared-network` and `egress-network` run in the network-owner account; `managed-monitoring`, `fleet-hub`, and the portal/fleet roles run on the hub; `org-*` components deploy to the management account only
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
druid, pipeline, governance.

Each tenant gets isolated AWS resources (databases, buckets, queues, Pod Identity roles).
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
  aws/
    workload-identity/     # EKS Pod Identity role factory
    platform-app/          # shared Pod-Identity association + app-access policy shell
    eks-vpc-endpoints/     # private endpoint set (create-mode network + shared-network)
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

- `ci.yml` — PRs: placeholders gate, fmt, validate (per-component matrix), tofu test, tflint, checkov, terragrunt evaluate (live-leaf render), mock-outputs cross-check, smoke-outputs cross-check, plan matrix
- `deploy.yml` — manual dispatch: account/region/environment/component, plan or apply
- `destroy.yml` — manual dispatch: development/staging only, requires confirmation string
- `drift.yml` — scheduled weekday drift detection on production + staging (matrix auto-discovered), creates GitHub issues
- `e2e.yml` — manual dispatch: provisions a real substrate, installs the operator, deploys a tenant via GitOps, then tears down (never scheduled — real spend)
- Auth: AWS OIDC (`AWS_ROLE_ARN` repo variable)
