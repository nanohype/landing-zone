# Onboarding Guide

Welcome to landing-zone. This guide gets you from zero to your first `plan` output.

## What This Repo Does

This repo provisions and manages cloud infrastructure across AWS, GCP, and Azure for the platform: networking, Kubernetes clusters (EKS/GKE/AKS), databases, queues, storage, IAM, monitoring, and cost controls. It uses OpenTofu for resource definitions and Terragrunt for environment orchestration.

**What it does NOT do:** in-cluster workloads (Kubernetes deployments, Helm releases beyond bootstrap). Those are managed by ArgoCD via the [eks-gitops](https://github.com/nanohype/eks-gitops) repo.

## Tool Installation

| Tool | Version | Install |
|------|---------|---------|
| [OpenTofu](https://opentofu.org/docs/intro/install/) | >= 1.11.0 | `brew install opentofu` |
| [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) | latest | `brew install terragrunt` |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | `brew install awscli` |
| [gcloud CLI](https://cloud.google.com/sdk/docs/install) | latest | `brew install google-cloud-sdk` |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | latest | `brew install azure-cli` |
| [TFLint](https://github.com/terraform-linters/tflint) | latest | `brew install tflint` |
| TFLint AWS plugin | 0.34.0 | `tflint --init -c .tflint-aws.hcl` |
| TFLint GCP plugin | 0.30.0 | `tflint --init -c .tflint-gcp.hcl` |
| TFLint Azure plugin | 0.27.0 | `tflint --init -c .tflint-azure.hcl` |

You only need the CLI and TFLint plugin for the cloud(s) you work with.

## Cloud Access

### AWS

Access is managed through AWS IAM Identity Center (SSO), configured by the `org-identity` component.

1. Get your SSO start URL and permission set from a platform engineer
2. Configure a profile:
   ```bash
   aws configure sso
   ```
3. Login:
   ```bash
   aws sso login --profile <your-profile>
   ```
4. Verify:
   ```bash
   aws sts get-caller-identity --profile <your-profile>
   ```

Set the profile as default or export `AWS_PROFILE` for Terragrunt to pick up.

### GCP

Access uses Google Cloud IAM, configured by the `org-identity` component.

1. Authenticate with the gcloud CLI:
   ```bash
   gcloud auth login
   ```
2. Set application-default credentials (required by OpenTofu):
   ```bash
   gcloud auth application-default login
   ```
3. Set your project:
   ```bash
   gcloud config set project <project-id>
   ```
4. Verify:
   ```bash
   gcloud auth list
   gcloud config get project
   ```

CI uses Workload Identity Federation -- no service account keys.

### Azure

Access uses Microsoft Entra ID, configured by the `org-identity` component.

1. Authenticate with the az CLI:
   ```bash
   az login
   ```
2. Set your subscription:
   ```bash
   az account set --subscription <subscription-id>
   ```
3. Verify:
   ```bash
   az account show
   ```

CI uses Federated Identity Credentials with OIDC -- no client secrets.

## Verify Setup

Run the local validation suite -- no cloud credentials needed:

```bash
make fmt-check && make validate CLOUD=aws && make lint CLOUD=aws
```

Replace `CLOUD=aws` with `gcp` or `azure` to validate other clouds. All three should pass. If `tflint` fails, make sure you ran `tflint --init -c .tflint-<cloud>.hcl` to install the plugin.

## Your First Plan

```bash
# AWS
make plan CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=network

# GCP
make plan CLOUD=gcp ACCOUNT=workload-dev REGION=us-central1 ENVIRONMENT=dev COMPONENT=network

# Azure
make plan CLOUD=azure ACCOUNT=workload-dev REGION=westus2 ENVIRONMENT=dev COMPONENT=network
```

This runs `terragrunt plan` for the network component in dev. You need valid cloud credentials for this step.

## Codebase Walkthrough

### `components/`

OpenTofu root modules organized by cloud: 24 AWS, 17 GCP, and 17 Azure components. Each is self-contained with `main.tf`, `variables.tf`, `outputs.tf`, and `versions.tf`. Seven AWS multi-tenant components also have a `modules/tenant/` sub-module.

Components define **what** to create. They are environment-agnostic -- no hardcoded account IDs, regions, or environment names.

### `live/`

Terragrunt configuration that wires components to environments.

- **`terragrunt.hcl`** (root) -- generates the cloud-specific provider (AWS/GCP/Azure) with default tags/labels and configures the state backend (S3/GCS/Azure Blob). Every environment inherits this.
- **`_envcommon/{cloud}/{name}.hcl`** -- one per component per cloud. Declares dependencies (which other components' outputs this one needs) and shared inputs.
- **`{cloud}/{account}/{region}/{env}/env.hcl`** -- environment-specific locals (identifiers, cost center, business unit, data classification, compliance, repository).
- **`{cloud}/{account}/{region}/{env}/{component}/terragrunt.hcl`** -- per-environment overrides (e.g., node counts, feature toggles, tenant maps).

### `modules/`

Shared sub-modules used across components:

- **`aws/workload-identity/`** -- IAM Roles for Service Accounts (IRSA) factory. Creates an IAM role with OIDC trust policy scoped to a specific Kubernetes namespace and service account.
- **`gcp/workload-identity/`** -- GKE Workload Identity binding. Binds a Kubernetes service account to a Google service account.
- **`azure/workload-identity/`** -- AKS Workload Identity. Creates a federated credential linking a Kubernetes service account to a managed identity.

### Key Files

- **`Makefile`** -- build automation (`fmt`, `validate`, `lint`, `plan`, `apply`) with `CLOUD` parameter
- **`.tflint-aws.hcl`**, **`.tflint-gcp.hcl`**, **`.tflint-azure.hcl`** -- per-cloud TFLint configurations
- **`scripts/init-backend-{aws,gcp,azure}.sh`** -- creates the state backend storage per cloud

## Key Concepts

### Workload Identity (per cloud)

| Cloud | Mechanism | Module |
|-------|-----------|--------|
| AWS | IRSA -- pods assume IAM roles via OIDC federation | `modules/aws/workload-identity/` |
| GCP | Workload Identity -- KSA bound to Google SA | `modules/gcp/workload-identity/` |
| Azure | Workload Identity -- federated credential on managed identity | `modules/azure/workload-identity/` |

Each cloud's workload identity module scopes access to a specific namespace and service account.

### Multi-Tenant Pattern

Seven AWS components (`druid`, `pipeline`, `gateway`, `llm`, `mlops`, `rag`, `governance`) accept a `var.tenants` map. Each key becomes a separate set of cloud resources via `for_each`. Tenants are isolated at the resource level (separate databases, buckets, queues, IAM roles). This pattern is currently AWS-only.

### GitOps Boundary

OpenTofu manages cloud resources plus the initial bootstrap of Cilium (CNI) and ArgoCD (via `cluster-bootstrap`). Once ArgoCD is running, it takes over all in-cluster workload management from the `eks-gitops` repo.

### Default Tags / Labels

The root `terragrunt.hcl` injects metadata on every resource. AWS uses `default_tags` (8 tags), GCP uses `default_labels` (8 labels, lowercase with underscores), and Azure tags are applied per-component. Components must not duplicate these.

### State Management

| Cloud | Backend | Locking | Bucket/Container Naming |
|-------|---------|---------|------------------------|
| AWS | S3 | Native conditional writes (`use_lockfile`) | `{account_id}-{region}-tfstate` |
| GCP | GCS | Native GCS locking | `{project_id}-{region}-tfstate` |
| Azure | azurerm (Blob) | Native blob leasing | `tfstate-rg` / `tfstate` container |

Each component in each environment has its own state file. State buckets are versioned and encrypted.

## Next Steps

- **First-time deploy walkthroughs** (account setup → running cluster):
  - [AWS](first-deploy-aws.md) — IAM Identity Center, EKS, AMP/AMG
  - [Azure](first-deploy-azure.md) — Entra ID admin user, AKS w/ NAP, AMW/AMG
  - [GCP](first-deploy-gcp.md) — GKE, Workload Identity, Cloud Monitoring
- [Architecture](architecture.md) -- design rationale, dependency graph, security model
- [Operations](operations.md) -- day-to-day procedures, CI/CD details
- [Runbooks](runbooks.md) -- incident procedures (drift, state locks, break-glass)
- [Troubleshooting](troubleshooting.md) -- common errors and fixes
