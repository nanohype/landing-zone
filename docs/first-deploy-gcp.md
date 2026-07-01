# First-Time GCP Deploy

Walkthrough for provisioning a brand-new GCP environment from a fresh project through to a running GKE cluster reconciled by ArgoCD against `gke-gitops` (when published).

Assumes you have a Google account, a Cloud billing account, and Owner on at least one project. If not, see [Account & Identity Setup](#account--identity-setup) first.

## Prerequisites

| Tool | Install | Why |
|---|---|---|
| gcloud CLI | `brew install google-cloud-sdk` | sign-in, project ops, quota |
| OpenTofu | `brew install opentofu` | resource provisioning |
| Terragrunt | `brew install terragrunt` | environment orchestration |
| kubectl | `brew install kubectl` | post-deploy verification |
| Task | `brew install go-task/tap/go-task` | runs the Taskfile wrappers |

## Account & Identity Setup

GCP's identity model differs from AWS's — there's a Google Account (yours, free) and Cloud IAM is layered on top, scoped to organizations / folders / projects.

### 1. Create your projects

```bash
gcloud auth login
gcloud auth application-default login   # required by OpenTofu

gcloud projects create <project-id-dev> --name="workload-dev"
gcloud projects create <project-id-staging> --name="workload-staging"
gcloud projects create <project-id-prod> --name="workload-prod"
```

Project IDs are globally unique. Pick something like `<yourorg>-workload-dev`.

### 2. Link billing

Find your billing account ID:

```bash
gcloud billing accounts list
```

Link each project:

```bash
gcloud billing projects link <project-id-dev>    --billing-account=<billing-account-id>
gcloud billing projects link <project-id-staging> --billing-account=<billing-account-id>
gcloud billing projects link <project-id-prod>   --billing-account=<billing-account-id>
```

Without billing linked, every API call returns a clear "billing not enabled" error — easy to catch but easy to forget.

### 3. (Optional) Set up an Organization + dedicated admin user

For a solo learner, your personal Google account as Owner on the projects is fine. For multi-user setup:

1. Create a Google Workspace or Cloud Identity tenant — required for Organization-level IAM
2. Create an `admins@yourdomain.com` group in Workspace
3. Grant the group **Organization Administrator** on the org
4. Add yourself + future admins to that group
5. Your daily Google account stays low-privilege; you join the group when you need to do admin work

For learning, skip this.

### 4. Enable 2-step verification

Use any TOTP app or a security key. Account → <https://myaccount.google.com/security> → 2-Step Verification → On.

### 5. Configure local CLI

```bash
gcloud config set project <project-id-dev>
gcloud auth list           # confirm your account is active
gcloud config get project  # confirm project context
```

CI eventually uses Workload Identity Federation (no service account keys), configured via `org-identity`.

## Pre-Deploy Setup

### 6. Update `account.hcl`

```bash
PROJECT_ID=$(gcloud config get project)
echo "project: $PROJECT_ID"
```

Edit `live/gcp/workload-<env>/account.hcl`:

```hcl
locals {
  project_id    = "<your-project-id>"
  account_alias = "workload-<env>"
}
```

### 7. Enable required GCP APIs

```bash
for api in container.googleapis.com compute.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com servicenetworking.googleapis.com secretmanager.googleapis.com dns.googleapis.com monitoring.googleapis.com logging.googleapis.com sqladmin.googleapis.com; do
  echo "Enabling $api..."
  gcloud services enable $api
done
```

`--async` if you want them to start in parallel (most return quickly anyway).

### 8. Bootstrap the state backend

Creates a GCS bucket `{project_id}-{region}-tfstate` with versioning + uniform bucket-level access. Idempotent.

```bash
PROJECT_ID=$(gcloud config get project)
./scripts/init-backend-gcp.sh $PROJECT_ID us-central1
```

### 9. Quota check

GCP defaults are similarly tight on a new project. Check the ones you'll need for GKE:

```bash
gcloud compute project-info describe --project $PROJECT_ID \
  --format="table(quotas.metric,quotas.limit,quotas.usage)" | head -20
```

Key quotas for GKE Autopilot or Standard with autoscaling:
- `CPUS` (per region) — at least 50 for prod
- `IN_USE_ADDRESSES` — at least 8
- `SUBNETWORKS` per region — usually fine at default 100

If under, file via console: `console.cloud.google.com/iam-admin/quotas → filter project = <your-project> → select metric → Edit Quotas`. Or CLI:

```bash
gcloud alpha services quota update \
  --service compute.googleapis.com \
  --consumer projects/$PROJECT_ID \
  --metric compute.googleapis.com/cpus \
  --region us-central1 \
  --value 200
```

### 10. Decide on private vs public cluster

Production overlay defaults to `enable_private_endpoint = true`. Same trade-off as the other clouds: private means no `kubectl` from laptop without IAP tunnel / VPN. For solo learning, flip to `false`:

```hcl
# live/gcp/workload-prod/us-central1/production/cluster/terragrunt.hcl
inputs = {
  enable_private_endpoint = false  # was true
  ...
}
```

## Deploy

```bash
cd <repo-root>

task apply CLOUD=gcp ACCOUNT=workload-<env> REGION=us-central1 ENVIRONMENT=<env> COMPONENT=network            # ~3-5 min
task apply CLOUD=gcp ACCOUNT=workload-<env> REGION=us-central1 ENVIRONMENT=<env> COMPONENT=cluster            # ~10-15 min (faster than EKS)
task apply CLOUD=gcp ACCOUNT=workload-<env> REGION=us-central1 ENVIRONMENT=<env> COMPONENT=secrets            # ~2 min
task apply CLOUD=gcp ACCOUNT=workload-<env> REGION=us-central1 ENVIRONMENT=<env> COMPONENT=cluster-bootstrap  # ~5-10 min
task apply CLOUD=gcp ACCOUNT=workload-<env> REGION=us-central1 ENVIRONMENT=<env> COMPONENT=cluster-addons     # ~5-10 min
```

### Get kubectl access (after `cluster` succeeds)

```bash
gcloud container clusters get-credentials <env>-gke --region us-central1 --project $PROJECT_ID
kubectl get nodes
```

GKE uses the gke-gcloud-auth-plugin (installed automatically with gcloud) — no equivalent of `kubelogin` setup needed.

### Watch the GitOps reconcile (after `cluster-bootstrap`)

```bash
kubectl -n argocd get applications --watch
```

## Post-Deploy

### Wire Google Service Account emails into gke-gitops

`cluster-addons` outputs the GSA emails for each Kubernetes workload identity binding:

```bash
cd live/gcp/workload-<env>/us-central1/<env>/cluster-addons
terragrunt output -json workload_identity_gsa_emails
terragrunt output -json gcs_buckets
```

Edit each `gke-gitops/addons/*/values-<env>.yaml`, replace placeholder `iam.gke.io/gcp-service-account` annotations with the real GSA emails. Open PR → merge → ArgoCD reconciles.

### Verify

```bash
kubectl -n argocd get applications
kubectl get pods -A | grep -vE 'Running|Completed'
```

## Optional Add-Ons

```bash
# Google Cloud Managed Service for Prometheus + Cloud Monitoring dashboards
task apply CLOUD=gcp ACCOUNT=workload-<env> REGION=us-central1 ENVIRONMENT=<env> COMPONENT=managed-monitoring

# Cloud DNS zone
task apply CLOUD=gcp ACCOUNT=workload-<env> REGION=us-central1 ENVIRONMENT=<env> COMPONENT=dns
```

## Cost Reality

Approximate $/day at default sizes:

| Setting | Dev | Production |
|---|---|---|
| GKE control plane (Standard) | $2.40 | $2.40 |
| Node pool | $4-6 (1-2× e2-standard-4) | $12 (3× e2-standard-4) |
| Workload-scaled nodes | $5-15 | $25-50 |
| Cloud NAT + reserved IPs | $1.50 | $1.50 |
| GCS + Persistent Disk | $0.50 | $1.50 |
| Secret Manager + Cloud DNS | $0.20 | $0.20 |
| **Baseline** | **~$14-25/day** | **~$43-67/day** |

GKE Autopilot would change these numbers — you pay per pod resource request rather than per node. Not currently used in this repo.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `gcloud auth login` succeeds but `application-default` is missing | only one of the two auths done | `gcloud auth application-default login` |
| `API X has not been used in project Y before or it is disabled` | API not enabled | `gcloud services enable <api>` per step 7 |
| `Billing account ... not found or user does not have access` | billing not linked or insufficient permission | step 2 + ensure your account has Billing Account User role |
| `task init-backend` says `Usage:` | Taskfile not forwarding args | Run directly: `./scripts/init-backend-gcp.sh $PROJECT_ID us-central1` |
| `terragrunt: Working dir components/gcp/X does not exist` | envcommon source path bug | Path must be `${dirname(find_in_parent_folders("cloud.hcl"))}/../../components/...` (`../..`) |
| `Quota exceeded` during cluster apply | regional CPU or IP quota too low | Console → IAM → Quotas → Edit, or `gcloud alpha services quota update` |
| `Insufficient regional quota to satisfy request: CPUS` | regional vs zonal quota distinction | Request the right scope; regional applies across zones |
| `kubectl` returns `Unable to connect to the server` | private cluster + no IAP tunnel | Flip `enable_private_endpoint = false` in cluster terragrunt + re-apply, or set up IAP TCP tunnel |
| Workload identity not working in pods | KSA annotation missing or GSA email wrong | `kubectl get sa <name> -n <ns> -o yaml` — should show `iam.gke.io/gcp-service-account: <gsa>@<project>.iam.gserviceaccount.com` |
| ArgoCD apps stuck OutOfSync | gke-gitops repo doesn't exist yet (project hasn't published) | TBD when gke-gitops lands |
