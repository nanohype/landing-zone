# landing-zone — agent entry point

You're an AI client (or the author of one) about to provision cloud substrate. This file gets you running in five minutes. For the wider picture — how this repo fits into the rest of the nanohype stack — read the [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md).

## What this repo gives you

OpenTofu + Terragrunt monorepo for the AWS substrate every nanohype-stack app lands on:

- **`components/aws/`** — VPC (`network`/`shared-network`/`egress-network`), base IAM, KMS keys, EKS cluster, cluster bootstrap, observability, secrets, gateway, governance, `agent-iam`, plus per-app `<app>-platform` single-tenant components (competitive-intelligence-platform, digest-pipeline-platform, incident-response-platform, slack-knowledge-bot-platform). Shared multi-tenant components (`var.tenants`): `druid`, `pipeline`, `gateway`, `llm`, `mlops`, `rag`, `governance`.

Plus:

- **`modules/`** — reusable building blocks components compose: `workload-identity` (the EKS Pod Identity role factory) and `platform-app` (the shared Pod Identity association + `<env>-<app>-app-access` policy shell every `<app>-platform` component binds through).
- **`live/`** — per-environment terragrunt configurations. Path is `live/aws/<account>/<region>/<env>/<component>/terragrunt.hcl`.

## Contract surface

Every component:

- Has its own `versions.tf` declaring `terraform >= 1.11.0` + AWS provider `~> 6.0`.
- Has its own `variables.tf` + `outputs.tf` + per-resource files.
- Reads from upstream component outputs via terragrunt `dependency` blocks declared in `live/_envcommon/aws/<component>.hcl`.
- Tags every resource with `Environment`, `ManagedBy`, `Project`, `CostCenter`, `BusinessUnit`, `DataClassification`, `Compliance`, `Repository` (default tags emitted by `live/root.hcl`).
- Uses EKS Pod Identity via the shared `modules/aws/workload-identity` module. Trust policies target `pods.eks.amazonaws.com` (not an OIDC provider), and each role is bound to a specific ServiceAccount in a specific namespace through an EKS Pod Identity association.

The per-app `<app>-platform` pattern: when an app's resource shape doesn't generalize into existing multi-tenant components, ship a single-tenant component named `<app>-platform`. Examples: `competitive-intelligence-platform`, `digest-pipeline-platform`, `incident-response-platform`, `slack-knowledge-bot-platform`. Each provisions the app's bespoke DDB tables, SQS queues, S3 buckets, RDS clusters, KMS keys, plus a consolidated `<app>-app-access` managed policy and the EKS Pod Identity association binding the app's ServiceAccount to the operator-reconciled `<env>-<app>-tenant` role. Bedrock model access is NOT granted here — it comes from the agent-iam tenant baseline, clamped by the operator to `Platform.spec.identity.allowedModels`; the app-access policy reaches the role through `Platform.spec.identity.extraPolicyArns`. Emits `app_access_policy_arn` for that spec entry.

## Add a new component

1. Create `components/aws/<name>/` with `versions.tf`, `variables.tf`, `main.tf`, `outputs.tf`, plus per-resource files (`rds.tf`, `s3.tf`, etc.).
2. Add `live/_envcommon/aws/<name>.hcl` declaring dependencies on upstream components (typically `network`, `cluster`, `cluster-bootstrap`).
3. Add `live/aws/<account>/<region>/<env>/<name>/terragrunt.hcl` per environment you want to provision (`workload-development`, `workload-staging`, `workload-production`).
4. Run `tofu fmt -recursive components/aws/<name>` and `tofu validate` from inside the component.
5. CI auto-discovers the new component via `git ls-files` — no workflow edit needed (`Validate (aws/<name>)` job materializes on the next PR).

## Add a per-app `<app>-platform` component

When the app's resource shape is bespoke (custom DDB schema, queues, multiple S3 buckets, app-specific KMS keys, SES identity, etc.):

1. Create `components/aws/<app>-platform/` following the incident-response/slack-knowledge-bot/digest-pipeline shape.
2. Provision the app's resources directly (not as `var.tenants` entries on multi-tenant components).
3. Consolidate the app's substrate permissions (everything except Bedrock invoke — that is operator territory, declared in `Platform.spec.identity.allowedModels`) into one `aws_iam_policy` named `<app>-<env>-app-access`, and bind the app's ServiceAccount to the operator-reconciled `<env>-<app>-tenant` role with an `aws_eks_pod_identity_association`. The Platform CR must be `Ready` before the association applies — bring-up order in `docs/first-deploy-aws.md` ("App platform tenants").
4. Output `app_access_policy_arn` (referenced from `Platform.spec.identity.extraPolicyArns`) plus every resource name/URL the chart needs (`<table>_name`, `<queue>_url`, etc.).
5. If the app touches a substrate service the tenant permissions boundary doesn't cover yet, extend `agent-iam`'s `TenantWorkloadCeiling` — the boundary caps every tenant role, so a grant outside it is silently clipped.
6. Add `live/_envcommon/aws/<app>-platform.hcl` and per-env `live/aws/workload-<env>/.../terragrunt.hcl`.

## Conventions

- All TF formatted with `tofu fmt -recursive`. CI's `Format Check` job blocks on drift.
- `tflint` runs repo-wide via the `.tflint-aws.hcl` config — a hard gate at `--minimum-failure-severity=notice`, so undocumented or unused declarations and missing version constraints fail the build. The uniform envcommon interface inputs carry inline `# tflint-ignore` rationale; nothing else may.
- Security scan via `checkov` — a hard gate (`soft_fail: false`); accepted posture trade-offs are enumerated in `.checkov.yaml`, one line of rationale each.
- Backend: per-component S3 state with native lockfile locking, generated by `live/root.hcl`.
- The `github-oidc` deploy-role trust scopes to `repo:nanohype/landing-zone` with environment-gated and tag-push subject claims (`allowed_subject_claims = ["environment:*", "ref:refs/tags/*"]`). A bare `:*` — which would also trust fork PRs and arbitrary branches — is deliberately excluded; widen `allowed_subject_claims` explicitly if the CI model needs another context.

## Pointers

- [`README.md`](README.md) — full repo overview
- [`docs/`](docs/) — architecture, OIDC setup, drift management
- [`CLAUDE.md`](CLAUDE.md) — Claude Code session instructions
- [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md) — the stack-wide view
- [`eks-agent-platform/AGENTS.md`](https://github.com/nanohype/eks-agent-platform/blob/main/AGENTS.md) — the operator that consumes Pod Identity role outputs from `<app>-platform` components
