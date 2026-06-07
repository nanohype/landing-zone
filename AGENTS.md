# landing-zone — agent entry point

You're an AI client (or the author of one) about to provision cloud substrate. This file gets you running in five minutes. For the wider picture — how this repo fits into the rest of the nanohype stack — read the [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md).

## What this repo gives you

OpenTofu + Terragrunt monorepo for the cloud substrate every nanohype-stack app lands on. Three providers, three concerns:

- **`components/aws/`** — VPC, base IAM, KMS keys, EKS cluster, cluster bootstrap, observability, secrets, gateway, governance, plus per-app `<app>-platform` single-tenant components (marshal-platform, slack-knowledge-bot-platform, dispatch-platform). Shared multi-tenant components: `rag`, `pipeline`, `llm`, `governance`.
- **`components/gcp/`** — equivalents for GCP (GKE, project IAM, KMS, observability, etc.). Same component shape, GCP primitives.
- **`components/azure/`** — equivalents for Azure (AKS, resource-group IAM, Key Vault, etc.). Same shape, Azure primitives.

Plus:

- **`modules/`** — reusable building blocks each component composes (`workload-identity` for IRSA, `eks-cluster-baseline`, etc.).
- **`live/`** — per-environment terragrunt configurations. Path is `live/<cloud>/<account>/<region>/<env>/<component>/terragrunt.hcl`.

## Contract surface

Every component:

- Has its own `versions.tf` declaring `terraform >= 1.10.0` + AWS provider `~> 6.0` (or equivalent per cloud).
- Has its own `variables.tf` + `outputs.tf` + provider-specific resource files.
- Reads from upstream component outputs via terragrunt `dependency` blocks declared in `live/_envcommon/<cloud>/<component>.hcl`.
- Tags every resource with `Environment`, `ManagedBy`, `Project`, `CostCenter`, `BusinessUnit`, `DataClassification`, `Compliance`, `Repository` (default tags emitted by `live/root.hcl`).
- For AWS: uses IRSA via the shared `modules/aws/workload-identity` module. Trust policies target the EKS cluster's OIDC provider and constrain to a specific SA in a specific namespace.

The per-app `<app>-platform` pattern: when an app's resource shape doesn't generalize into existing multi-tenant components, ship a single-tenant component named `<app>-platform`. Examples: `marshal-platform`, `slack-knowledge-bot-platform`, `dispatch-platform`. Each provisions the app's bespoke DDB tables, SQS queues, S3 buckets, RDS clusters, KMS keys, and the IRSA role with the consolidated inline policy. Emits `irsa_role_arn` as the output the app's chart consumes via `aws.platformRoleArn`.

## Add a new component

1. Create `components/<cloud>/<name>/` with `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`, plus per-resource files (`rds.tf`, `s3.tf`, etc.).
2. Add `live/_envcommon/<cloud>/<name>.hcl` declaring dependencies on upstream components (typically `network`, `cluster`, `cluster-bootstrap`).
3. Add `live/<cloud>/<account>/<region>/<env>/<name>/terragrunt.hcl` per environment you want to provision (`workload-dev`, `workload-staging`, `workload-prod`).
4. Run `tofu fmt -recursive components/<cloud>/<name>` and `tofu validate` from inside the component.
5. CI auto-discovers the new component via `git ls-files` — no workflow edit needed (`Validate (<cloud>/<name>)` job materializes on the next PR).

## Add a per-app `<app>-platform` component

When the app's resource shape is bespoke (custom DDB schema, queues, multiple S3 buckets, app-specific KMS keys, SES identity, etc.):

1. Create `components/aws/<app>-platform/` following the marshal/slack-knowledge-bot/dispatch shape.
2. Provision the app's resources directly (not as `var.tenants` entries on multi-tenant components).
3. Consolidate all the app's IAM permissions into a single inline policy on a single IRSA role via `modules/aws/workload-identity`.
4. Output `irsa_role_arn` (the app's chart consumes this) plus every resource name/URL the chart needs (`<table>_name`, `<queue>_url`, etc.).
5. Add `live/_envcommon/aws/<app>-platform.hcl` and per-env `live/aws/workload-<env>/.../terragrunt.hcl`.

## Conventions

- All TF formatted with `tofu fmt -recursive`. CI's `Format Check` job blocks on drift.
- `tflint` runs cloud-wide via `.tflint-<cloud>.hcl` configs.
- Security scan via `checkov` (advisory — `soft_fail: true` keeps CI green while surfacing findings).
- Backend: per-env S3 + DynamoDB lock table, configured in `live/<cloud>/<account>/<region>/<env>/backend.hcl`.
- GitHub OIDC trust policies must include both `repo:nanohype/landing-zone:*` (current) — outdated `stxkxs/*` trust is a known cross-cutting fix tracked outside this repo.

## Pointers

- [`README.md`](README.md) — full repo overview
- [`docs/`](docs/) — multi-cloud architecture, OIDC setup, drift management
- [`CLAUDE.md`](CLAUDE.md) — Claude Code session instructions
- [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md) — the stack-wide view
- [`eks-agent-platform/AGENTS.md`](https://github.com/nanohype/eks-agent-platform/blob/main/AGENTS.md) — the operator that consumes IRSA outputs from `<app>-platform` components
