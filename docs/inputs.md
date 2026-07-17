# Inputs Catalog

Every value an operator must supply to stand up an environment, and where it
lives. Terragrunt resolves inputs bottom-up: `account.hcl` → `region.hcl` →
`env.hcl` → each component's `_envcommon/*.hcl`. `root.hcl` reads the first three
and injects `region` + `environment` into every component plus the org-wide
`default_tags`.

There is no `.env` file — these are HCL `locals`, tracked in git except where a
placeholder + env-var override keeps a real value out of the tree (account id).

## Per-account — `live/aws/<account>/.../account.hcl`

| Local | Example | Notes |
|-------|---------|-------|
| `account_id` | `"111122223333"` | The tracked file holds a **placeholder**. CI/automation injects the real id via the `TERRAGRUNT_ACCOUNT_ID` env var (`root.hcl` falls back to `account.hcl` for local deploys). A real account id must never land in a tracked file. |

## Per-region — `live/aws/.../region.hcl`

| Local | Example | Notes |
|-------|---------|-------|
| `region` | `"us-west-2"` | Declared (no default) by every component; passed down from `root.hcl`. |

## Per-environment — `live/aws/.../<env>/env.hcl`

These populate the org-wide `default_tags` (rendered as AWS PascalCase per the
resource-tagging standard) and are the identity every resource inherits.

| Local | Required? | Example | Renders as tag |
|-------|-----------|---------|----------------|
| `environment` | yes | `"development"` | `Environment` |
| `cost_center` | yes | `"platform-engineering"` | `CostCenter` |
| `business_unit` | yes | `"engineering"` | `BusinessUnit` |
| `data_classification` | yes | `"internal"` | `DataClassification` |
| `compliance` | yes | `"soc2"` | `Compliance` |
| `repository` | yes | `"nanohype/landing-zone"` | `Repository` |
| `owner` | optional | `"platform-engineering"` | `Owner` (falls back to `cost_center`) |

`environment` must match `^[a-z][a-z0-9-]*$` (enforced by variable validation in
every component).

## Injected by CI — environment variables

| Var | Purpose |
|-----|---------|
| `TERRAGRUNT_ACCOUNT_ID` | real AWS account id (overrides the `account.hcl` placeholder) |
| `GITHUB_SHA` | short commit → the `Revision` tag; `"local"` off-CI |
| `AWS_ROLE_ARN` | the OIDC deploy role CI assumes (repo Variable; unset ⇒ Plan jobs skip green) |

## Component-specific — `live/_envcommon/aws/<component>.hcl`

Beyond the common inputs, each component declares its own. The ones an operator
most often sets:

| Input | Component(s) | Notes |
|-------|--------------|-------|
| `team` | all | owning team → `Team` tag (e.g. `platform`, `data-platform`, `sre`) |
| `cluster_name` | `cluster`, addons | base name, prefixed with `environment` |
| `cluster_version` | `cluster` | Kubernetes `major.minor`, e.g. `"1.36"` (regex-validated) |
| `eks_addon_versions` | `cluster` | pinned addon versions; re-pin when `cluster_version` moves |
| `cluster_endpoint_public_access` + `..._cidrs` | `cluster` | **not set in the committed tree** — private by default; posture is supplied by rackctl at apply time (see [EKS API endpoint posture](#eks-api-endpoint-posture)) |
| `tenants` | `druid`, `pipeline`, `llm`, `mlops`, `rag` | per-tenant maps (one IRSA/Pod-Identity role each) |
| `cluster_iam_role_path` + `cluster_permissions_boundary_arn` | `cluster` | set for cross-account fleet-vend gating; defaults `/` + empty = same-account |

## EKS API endpoint posture

Two `cluster` inputs decide whether the EKS API server is reachable from the public
internet:

| Input | Type | Default | Meaning |
|-------|------|---------|---------|
| `cluster_endpoint_public_access` | `bool` | `false` | `true` exposes a public API endpoint; `false` keeps it private (VPC-only, reached via bastion/VPN) |
| `cluster_endpoint_public_access_cidrs` | `list(string)` | `[]` | allow-list for the public endpoint. **Required (non-empty) whenever public access is on** — the component fails closed at plan time; there is no `0.0.0.0/0` fallback |

**The committed tree does not set either one.** Every `live/.../cluster/terragrunt.hcl`
leaf inherits the component's own `false` default, so it is private-by-default and plans
clean with zero external input — a plan from a fresh checkout never opens the control
plane and never trips the fail-closed CIDR validation.

Posture is a fragile, per-run choice, so it is owned by
[rackctl](https://github.com/rackctl/rackctl), not committed. rackctl's `cluster` phase
reads `cluster.endpointPublicAccess` and `cluster.endpointAllowlist` from `rackctl.yaml`
and exports them onto the terragrunt runner as two `TF_VAR`s that layer over the generic
committed tree:

| `TF_VAR` | Carries | Shape |
|----------|---------|-------|
| `TF_VAR_cluster_endpoint_public_access` | the bool | `true` / `false` |
| `TF_VAR_cluster_endpoint_public_access_cidrs` | the allow-list | JSON array, e.g. `["203.0.113.4/32"]` |

When public access is requested with an empty allow-list, rackctl auto-detects the
operator's public egress IP and scopes the endpoint to `<ip>/32` rather than opening it
to the world — a public endpoint is never provisioned without an allow-list.

To reproduce the rackctl-supplied path on a manual `task` deploy (terragrunt forwards
`TF_VAR_*` to tofu), export the pair before applying `cluster`:

```bash
export TF_VAR_cluster_endpoint_public_access=true
export TF_VAR_cluster_endpoint_public_access_cidrs="[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
task plan ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=cluster
```

Leave them unset for a private endpoint.

## Bringing up a new environment — checklist

1. Create `account.hcl` (placeholder id), `region.hcl`, `env.hcl` under a new
   `live/aws/<account>/<region>/<env>/` path.
2. Fill the six required `env.hcl` locals above.
3. Set `AWS_ROLE_ARN` (repo Variable) and the OIDC trust for the new repo/env.
4. `terragrunt run-all plan` from the env dir; deploy components in dependency
   order (see [architecture.md](architecture.md) Dependency Graph).
