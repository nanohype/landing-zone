# First-Time AWS Deploy

Walkthrough for provisioning a brand-new AWS environment from a fresh account through to a running EKS cluster reconciled by ArgoCD against `eks-gitops`.

Assumes you have an AWS account and `root` access (the email/password used to sign up). If you don't, see [Account & Identity Setup](#account--identity-setup) first.

## Prerequisites

| Tool | Install | Why |
|---|---|---|
| AWS CLI v2 | `brew install awscli` | sign-in, account ops, quota |
| OpenTofu | `brew install opentofu` | resource provisioning |
| Terragrunt | `brew install terragrunt` | environment orchestration |
| kubectl | `brew install kubectl` | post-deploy verification |
| Task | `brew install go-task/tap/go-task` | runs the Taskfile wrappers |

## Account & Identity Setup

The root account (the email you signed up with) should never be used for daily work. Bootstrap an IAM Identity Center admin user instead.

### 1. Enable IAM Identity Center

This is the AWS equivalent of Microsoft Entra ID — federated SSO sitting on top of IAM.

1. Sign in as root at <https://signin.aws.amazon.com> using the signup email
2. Console → search **"IAM Identity Center"** → click **Enable**
3. Pick an **Identity source**: Identity Center directory (built-in) is the simplest. Microsoft Entra ID or Okta if you have them.
4. Note your **AWS access portal URL** (looks like `https://d-1234567890.awsapps.com/start`)

### 2. Create your admin user

IAM Identity Center → **Users → Add user**:

- Username: `<yourname>-admin`
- Email: a real address you control (must verify)
- First/Last name: yours
- Display name: `<Your Name> Admin`

After creation, set the user's password via the email verification link.

### 3. Create a permission set + assign

IAM Identity Center → **Permission sets → Create permission set**:

- Predefined permission set → **AdministratorAccess**
- Session duration: 12 hours
- Name: `AdministratorAccess`

Then **AWS accounts** → select your account → **Assign users or groups** → pick `<yourname>-admin` → attach the `AdministratorAccess` permission set.

### 4. Enable MFA on the admin user

IAM Identity Center → **Settings → Authentication → MFA settings**:

- Prompt users for MFA: **Every time they sign in**
- MFA types: **Authenticator apps** (TOTP)

When you next sign in as `<yourname>-admin`, you'll be forced to enroll. Use any TOTP app (1Password, Authy, Microsoft/Google Authenticator).

### 5. Lock down the root account

While still signed in as root, AWS console → top-right account name → **Security credentials**:

- **Account security recommendations** → MFA → **Assign MFA device** → register a TOTP method
- Generate a long random password (64+ chars) → store in password manager. You should not use root for anything except billing and account-deletion scenarios.

Sign out as root. Sign in via the IAM Identity Center portal URL as `<yourname>-admin` from now on.

### 6. Configure local CLI

```bash
aws configure sso
# SSO start URL: <your access portal URL>
# SSO Region: us-east-1 (or wherever Identity Center is hosted)
# CLI default region: us-east-1
# CLI default output: json
# Profile name: workload-development (or whatever)

aws sso login --profile workload-development
aws sts get-caller-identity --profile workload-development
```

Export `AWS_PROFILE=workload-development` (or set it per-shell) so Terragrunt picks it up automatically.

## Pre-Deploy Setup

### 7. Update `account.hcl`

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "account: $ACCOUNT_ID"
```

Edit `live/aws/workload-<env>/account.hcl`:

```hcl
locals {
  account_id    = "<your-account-id>"
  account_alias = "workload-<env>"
}
```

### 8. Bootstrap the state backend

Creates an S3 bucket `{account_id}-{region}-tfstate` with versioning + encryption. Idempotent.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
./scripts/init-backend-aws.sh $ACCOUNT_ID us-east-1
```

### 9. Service quotas

AWS imposes per-region quotas on resources like EC2 instances, EIPs, NAT Gateways, and VPCs. Defaults for a new account are very tight (e.g., 5 EIPs, 5 VPCs per region, 32 vCPUs for On-Demand standard instances).

Check current limits:

```bash
aws service-quotas list-service-quotas --service-code ec2 --region us-east-1 \
  --query "Quotas[?QuotaCode=='L-1216C47A'].{Quota:QuotaName,Limit:Value}" \
  --output table
```

`L-1216C47A` is "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances." For prod EKS with Karpenter, you want at least 256.

File an increase via console or CLI:

```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 \
  --quota-code L-1216C47A \
  --desired-value 256 \
  --region us-east-1
```

Most On-Demand quota increases are auto-approved within 15-30 minutes. EIP increases can take longer (manual review).

### 10. Decide on public vs private cluster endpoint

Every committed `cluster` leaf is **private by default** — the API endpoint is reachable only from inside the VPC (bastion/VPN), and the tree plans clean with no endpoint input at all. Posture is not hand-edited into the tree; it is supplied at apply time as two `TF_VAR`s (see [inputs.md](inputs.md#eks-api-endpoint-posture)). rackctl sets them from `rackctl.yaml`, auto-detecting your egress IP when you ask for public access without an allow-list.

To reach the API from your laptop on a manual deploy, export the pair before `task apply ... COMPONENT=cluster`:

```bash
export TF_VAR_cluster_endpoint_public_access=true
export TF_VAR_cluster_endpoint_public_access_cidrs="[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
```

Leave them unset for a private endpoint. A public endpoint with an empty allow-list is rejected at plan time — there is no `0.0.0.0/0` fallback.

## Deploy

```bash
cd <repo-root>

task apply ACCOUNT=workload-<env> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=network            # ~3-5 min
task apply ACCOUNT=workload-<env> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=cluster            # ~15-25 min
task apply ACCOUNT=workload-<env> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=secrets            # ~2 min
task apply ACCOUNT=workload-<env> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=cluster-bootstrap  # ~5-10 min
task apply ACCOUNT=workload-<env> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=cluster-addons     # ~5-10 min
```

Replace `<env>` with `development`/`staging`/`production` and account accordingly.

### Get kubectl access (after `cluster` succeeds)

```bash
aws eks update-kubeconfig --name <env>-platform --region us-east-1 --profile workload-<env>
kubectl get nodes
```

### Watch the GitOps reconcile (after `cluster-bootstrap`)

```bash
kubectl -n argocd get applications --watch
```

Bootstrap creates the App-of-Apps Application pointing at `eks-gitops`. Applications progress `OutOfSync` → `Syncing` → `Healthy` over ~15-25 min. Karpenter provisions nodes as addons schedule.

## Post-Deploy

### Wire Pod Identity role ARNs into eks-gitops

`cluster-addons` outputs the real role ARNs that need to replace the `000000000000` placeholders:

```bash
cd live/aws/workload-<env>/us-east-1/<env>/cluster-addons
terragrunt output -json pod_identity_role_arns
terragrunt output -json s3_bucket_names
```

Edit each `eks-gitops/addons/*/values-<env>.yaml`, replace the placeholder account IDs with the real values. Open PR → merge → ArgoCD reconciles.

### Observability endpoints (wired automatically)

`managed-monitoring` (the AMP + AMG component) publishes its endpoints to source, and the gitops layer resolves them with no hand-editing:

- The AMP query + remote-write URLs go to a Secrets Manager secret. External Secrets syncs them into the cluster, where **grafana-agent** reads `AMP_REMOTE_WRITE_URL` from the synced Secret and the **dashboards data source** templates its AMP URL from it via `GrafanaDatasource.valuesFrom`.
- The AMG workspace URL goes to SSM. `cluster-bootstrap` reads it and stamps it onto the ArgoCD cluster Secret as the `monitoring/grafana-url` annotation, which the dashboards ApplicationSet injects into the `Grafana` CR's external URL.

So once `managed-monitoring` is applied and External Secrets plus the `aws-secrets-manager` ClusterSecretStore are healthy, the endpoints flow automatically — there is nothing to substitute by hand, in any environment including the hub.

**Smoke test** (after the agent rolls out): query `count(kube_customresource_status_phase)` in the AMG explore view and confirm it's non-zero, or check the grafana-agent pod logs for successful `prometheus.remote_write` to AMP (no 4xx/SigV4 errors).

### Verify

```bash
kubectl -n argocd get applications
kubectl get pods -A | grep -vE 'Running|Completed'
```

## Optional Add-Ons

```bash
# Amazon Managed Prometheus + Amazon Managed Grafana
task apply ACCOUNT=workload-<env> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=managed-monitoring

# Druid analytics tenant
task apply ACCOUNT=workload-<env> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=druid

# Route 53 hosted zone (if attaching ingress hostnames)
task apply ACCOUNT=workload-<env> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=dns
```

After `managed-monitoring`, bootstrap the Amazon Managed Grafana service-account token into Secrets Manager (one-time):

```bash
AMG_ID=$(cd live/aws/workload-<env>/us-east-1/<env>/managed-monitoring && terragrunt output -raw grafana_workspace_id)

SA=$(aws grafana create-workspace-service-account \
  --workspace-id $AMG_ID \
  --grafana-role ADMIN \
  --name terraform \
  --query serviceAccount.id --output text)

TOKEN=$(aws grafana create-workspace-service-account-token \
  --workspace-id $AMG_ID \
  --service-account-id $SA \
  --name token \
  --seconds-to-live 2592000 \
  --query serviceAccountToken.key --output text)

aws secretsmanager create-secret \
  --name eks-grafana-token \
  --secret-string "{\"token\":\"$TOKEN\"}"
```

## App platform tenants

App workloads (the Platform tenants deployed through eks-gitops) run on the
operator-reconciled `<env>-<app>-tenant` role, as the operator-owned
`tenant-runtime` ServiceAccount. Everything the role grants is generated from
the app's `Platform` CR: Bedrock model access from `spec.identity`
(`allowedModelFamilies` / `allowedModels`), the substrate grants (DynamoDB, SQS,
S3, Secrets Manager, …) from `spec.datastores`, and SES / EventBridge Scheduler
from `spec.identity.capabilities`. The stores themselves are provisioned by the
generic `tenant-substrate` component from that same declaration. Bring a tenant
up in this order:

1. `agent-iam` (tenant boundary, baseline, operator role) — part of the core
   Deploy sequence above.
2. `task apply … COMPONENT=tenant-substrate` — provisions the tenant's declared
   datastores (its `var.tenants` map is rendered from the Platform CRs).
3. Apply the app's `Platform` CR. The operator mints the tenant role, generates
   its datastore-access + capability-access policies, creates the
   `tenant-runtime` ServiceAccount, and binds it via a Pod Identity association.
   Wait for `Ready`.
4. Register the app's ApplicationSet entry in eks-gitops; ArgoCD syncs the
   chart.

Design facts at this seam:

- **The kill-switch reaches app pods.** A BudgetPolicy breach detaches the
  baseline from the tenant role — model access zeroes instantly while
  substrate access persists, so the app degrades to its no-LLM behavior
  instead of falling over.
- **One privilege domain per Platform.** App pods and AgentFleet pods share
  the tenant role; workloads that must not share substrate access belong in
  separate Platforms.
- **Model changes are spec changes.** Pointing an app at a new model is a
  `platform.yaml` edit converged by the operator — no tofu plan, no IAM edit.

## Cost Reality

Approximate $/day at default sizes:

| Setting | Development | Production |
|---|---|---|
| EKS control plane | $2.40 | $2.40 |
| System node pool | $4-6 (1-2× m5.large) | $14 (3× m5.large) |
| Karpenter-provisioned addons | $5-15 | $25-50 |
| NAT Gateways (3) + EIPs | $3 | $3 |
| S3 + EBS | $0.50 | $1.50 |
| Secrets Manager + Route 53 | $0.30 | $0.30 |
| **Baseline** | **~$15-25/day** | **~$45-70/day** |
| +Managed monitoring (AMP+AMG) | +$3/day | +$5-8/day |
| +Druid | +$40/day | +$50/day |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `aws sso login` opens browser but auth never completes | popup blocker, or wrong start URL | Verify URL with `aws configure sso list`. Try `aws sso login --no-browser` for a code-based flow. |
| `Unable to locate credentials` from terragrunt | `AWS_PROFILE` not set | `export AWS_PROFILE=workload-<env>` |
| `terragrunt: Working dir components/aws/X does not exist` | envcommon source path bug | Path must be `${dirname(find_in_parent_folders("cloud.hcl"))}/../../components/...` (`../..`) |
| `LimitExceeded: ... vCPUs ... cannot be increased` during cluster | quota too low | Request increase via Service Quotas console / `aws service-quotas request-service-quota-increase` |
| EKS cluster create fails with `InvalidParameterException` re: SG/subnet | network module didn't fully complete | Re-apply `network`, then re-apply `cluster` |
| `cluster-bootstrap` connects but fails RBAC | IAM principal not in cluster access entries | Update `live/aws/workload-<env>/.../cluster/terragrunt.hcl` access_entries map, re-apply `cluster` |
| ArgoCD apps stuck in OutOfSync, "repository not accessible" | eks-gitops URL wrong or repo private | Verify https://github.com/nanohype/eks-gitops loads anonymously |
| Addons stuck Pending | Karpenter not provisioning | `kubectl get nodepool && kubectl describe nodepool default` |

## Execution model: local (default) vs CI

`deploy` and the end-to-end harness run **locally** with your SSO credentials —
the `aws sso login --profile workload-<env>` + `AWS_PROFILE` setup above is all
you need. There is no GitHub Actions runner in the default model; `task apply`
and `task e2e` execute on your machine against the target account.

The repo also ships GitHub Actions workflows (`deploy.yml`, `destroy.yml`,
`e2e.yml`) for an **optional** CI path. Those assume a GitHub→AWS OIDC role,
which the `github-oidc` component provisions (the OIDC provider + a repo-scoped
deploy role). Apply it once per account with your admin/SSO creds, then wire its
output into GitHub Actions *variables*:

```bash
task apply ACCOUNT=workload-<env> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=github-oidc
cd live/aws/workload-<env>/us-east-1/<env>/github-oidc && terragrunt output -raw deploy_role_arn
# deploy.yml / destroy.yml: on the <env> GitHub Environment (Settings >
# Environments > <env> > Environment variables) set DEPLOY_ROLE_ARN to the
# printed ARN and DEPLOY_ACCOUNT_ID to the workload-<env> account's 12-digit id.
# e2e.yml: set E2E_AWS_ROLE_ARN. Local exec does not need any of this.
```

Only `workload-development` has a `github-oidc` leaf today. For staging and
production, create the `live/aws/workload-<env>/us-east-1/<env>/github-oidc/`
leaf first; the `task apply` above has nothing to run until it exists.

`deploy.yml` and `destroy.yml` declare `environment: <env>` and read
`DEPLOY_ROLE_ARN` and `DEPLOY_ACCOUNT_ID`, which are set on GitHub Environments
only, so each of `development`, `staging` and `production` carries its own
account's role and id. A GitHub variable an environment does not set falls back
to the repository's and then the organization's, which is why these are not
`AWS_ROLE_ARN` and `TERRAGRUNT_ACCOUNT_ID` (the repository-level plan-role
pair): with those names, an environment that forgot its own would silently use
the plan role and the repository's account id. Both workflows refuse to run while
either `DEPLOY_*` name is set at repository or organization level, fail before
assuming anything when the environment does not set either one, and fail after
assuming the role when its account is not `DEPLOY_ACCOUNT_ID`. They run only the
`workload-<env>` leaves; see
[operations.md](operations.md#deployyml----manual-deploy).

The role ships with **no permissions** — its trust is scoped to the four GitHub
Environments the deploy, destroy and e2e workflows declare
(`repo:nanohype/landing-zone:environment:development`,
`repo:nanohype/landing-zone:environment:staging`,
`repo:nanohype/landing-zone:environment:production` and
`repo:nanohype/landing-zone:environment:e2e`; the `workload-development` leaf
narrows that to `development` and `e2e`), never the `plan` or `drift`
environment the read-only plan role trusts — and you attach the policies CI needs via the
component's `managed_policy_arns` (e.g. `AdministratorAccess` with a
`permissions_boundary_arn`, or a scoped set). Skip this component entirely if you
only run locally.

Before attaching any policy, give every environment the role trusts a
deployment-branch policy in the repository settings (main, or protected
branches), and required reviewers on `staging`, `production` and `e2e`. The
trust names environments, not refs: a job that declares `environment: production`
presents the same `sub` from any branch, and `deploy.yml`, `destroy.yml` and
`e2e.yml` can be dispatched from any branch. An environment that does not exist
yet is created unprotected the first time a workflow names it.

The repository-level `AWS_ROLE_ARN` variable is the development account's
**plan** role (`plan_role_arn`), which ci.yml's plan job assumes from
`environment: plan`. drift.yml assumes each staging or production account's own
plan role from a different environment, `drift`, which admits `main` only, and
reads it from `DRIFT_PLAN_ROLE_ARNS`, a secret on that environment mapping
account directory to `plan_role_arn` (see
[operations.md](operations.md#driftyml----drift-detection)). The deploy role
trusts neither environment, so a `deploy_role_arn` in either place makes PR
plans or drift detection fail at the credential step; in drift.yml that failure
files a `drift-error` issue for each of the account's leaves and turns the run
red.

Arming drift detection takes a plan role in every account directory that holds
a `staging` or `production` leaf (`workload-staging`, `workload-production`,
`network` and `backup`): the account's state backend created, one
`github-oidc` leaf per account with `plan_allowed_subject_claims =
["environment:drift"]` applied locally with that account's credentials, and its
`plan_role_arn` recorded in the `DRIFT_PLAN_ROLE_ARNS` secret on the `drift`
environment once that account's `staging` and `production` leaves have been
applied. The per-account list is in
[operations.md](operations.md#arming-drift-detection-one-plan-role-per-account).

**Required before any of those leaves:** the `drift` GitHub Environment, with a
deployment-branch policy admitting `main` only and no required reviewers, and
the `DRIFT_PLAN_ROLE_ARNS` secret on it (single-line JSON, set on no repository
or organization level, as a secret or as a variable). Create the environment
before drift.yml declares it: a workflow naming a missing environment creates it
unprotected.

```bash
gh api -X PUT repos/nanohype/landing-zone/environments/drift \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST repos/nanohype/landing-zone/environments/drift/deployment-branch-policies \
  -f name=main -f type=branch
jq -c . drift-plan-role-arns.json | gh secret set DRIFT_PLAN_ROLE_ARNS --env drift --repo nanohype/landing-zone
```

The component holds the trust to that environment, keyed on the account rather
than on the leaf's directory (envcommon passes every environment the account
holds as `account_environments`): in an account holding `staging` or
`production`, `plan_allowed_subject_claims` must be exactly
`["environment:drift"]` and `github_repos` exactly `["landing-zone"]`, even for
a leaf under that account's `development` directory; `environment:plan` is
refused outside the development-only account; and an account holding neither
(management, fleet, shared-services) takes `create_plan_role = false`. Delete
any repository-level `DRIFT_PLAN_ROLE_ARNS` variable before the drift change
merges, and never run drift.yml with debug logging while one exists: a debug
run traces the value of a variable, unmasked. The full checklist is in
[operations.md](operations.md#required-before-any-staging-or-production-plan-role).

## End-to-end validation (`task e2e`)

A single manual command provisions a throwaway substrate, installs the operator,
deploys a tenant via GitOps, asserts tenant-role + cloudgov conformance, and tears
everything down — always, even on failure (an EXIT trap), so a broken run never
leaves billing on:

```bash
E2E_ACCOUNT_ID=<account-id> AWS_PROFILE=workload-<env> task e2e
```

It's real, billable AWS (~$0.30-0.60 for a ~30-45 min run on the development tree) and is
**never scheduled** — run it on demand to confirm the whole stack still holds
together. See `scripts/e2e.sh` for the full set of knobs and prerequisites.
