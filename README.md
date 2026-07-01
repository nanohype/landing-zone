# landing-zone

![OpenTofu](https://img.shields.io/badge/OpenTofu-%3E%3D1.11-blue?logo=opentofu)
![Terragrunt](https://img.shields.io/badge/Terragrunt-latest-blue?logo=terraform)
![AWS](https://img.shields.io/badge/AWS-Platform-FF9900?logo=amazonaws)
![GCP](https://img.shields.io/badge/GCP-Platform-4285F4?logo=googlecloud)
![License](https://img.shields.io/badge/License-MIT-green)

Multi-cloud OpenTofu + Terragrunt monorepo for enterprise platform infrastructure.

**AI clients / agents start here:** [`AGENTS.md`](AGENTS.md). For the stack-wide view, see the [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md).

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Organization Layer (management / org accounts)                     │
│  org-identity · org-security · org-compliance · org-cost            │
│  org-networking · org-scp/org-policy                                │
└─────────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Environment Layer (dev / staging / production)                     │
│                                                                     │
│  ┌──────────┐    ┌──────────┐    ┌──────────────────────────────┐  │
│  │ network  │───▶│ cluster  │───▶│ druid · pipeline · llm       │  │
│  │          │    │          │───▶│ gateway · rag · mlops         │  │
│  │          │    │          │───▶│ governance · observability    │  │
│  │          │    │          │───▶│ secrets                       │  │
│  │          │    │          │───▶│ cluster-addons                │  │
│  │          │    │          │───▶│ cluster-bootstrap             │  │
│  └──────────┘    └──────────┘    └──────────────────────────────┘  │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │ backup · break-glass · service-quotas · cost · dns           │  │
│  │ (standalone — no dependencies)                                │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

**Multi-cloud hierarchy:**

```
live/{cloud}/{account}/{region}/{environment}/{component}/terragrunt.hcl
```

**GitOps boundary:** OpenTofu deploys cloud resources + Cilium + ArgoCD. ArgoCD manages everything else via [eks-gitops](https://github.com/nanohype/eks-gitops).

## Repository Structure

```
landing-zone/
├── components/
│   ├── aws/                # AWS OpenTofu root modules
│   └── gcp/                # GCP OpenTofu root modules
├── live/
│   ├── root.hcl            # Root config (multi-cloud provider dispatch)
│   ├── _envcommon/
│   │   ├── aws/            # AWS dependency wiring (24 .hcl)
│   │   └── gcp/            # GCP dependency wiring
│   ├── aws/
│   │   ├── cloud.hcl
│   │   ├── management/     # Management account (org components)
│   │   ├── workload-dev/   # Dev account
│   │   ├── workload-staging/
│   │   └── workload-prod/
│   └── gcp/
│       ├── cloud.hcl
│       ├── workload-dev/
│       ├── workload-staging/
│       └── workload-prod/
├── modules/
│   ├── aws/workload-identity/    # AWS IRSA role factory
│   └── gcp/workload-identity/    # GKE Workload Identity binding
├── scripts/
│   ├── init-backend-aws.sh
│   └── init-backend-gcp.sh
├── Taskfile.yaml
├── .tflint.hcl              # Base rules
├── .tflint-aws.hcl          # AWS plugin
└── .tflint-gcp.hcl          # GCP plugin
```

## Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.10.0
- [Terragrunt](https://terragrunt.gruntwork.io/) (latest)
- Cloud CLI tools: [AWS CLI v2](https://aws.amazon.com/cli/), [gcloud](https://cloud.google.com/sdk)
- [TFLint](https://github.com/terraform-linters/tflint) with cloud-specific plugins

## Quick Start

```bash
# 1. Clone and configure
git clone <repo-url> && cd landing-zone
# Update account IDs in live/{cloud}/{account}/account.hcl

# 2. Create backend infrastructure
./scripts/init-backend-aws.sh <account_id> <region>
./scripts/init-backend-gcp.sh <project_id> <region>

# 3. Plan all AWS dev components
task plan CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev

# 4. Apply a single component
task apply CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=network
```

## Task Targets

```
task fmt              Format all OpenTofu files
task fmt:check        Check formatting without modifying files
task validate         Validate all components for CLOUD (default: aws)
task lint             Run TFLint for CLOUD (default: aws)
task plan             Plan for CLOUD/ACCOUNT/REGION/ENVIRONMENT/COMPONENT
task apply            Apply for CLOUD/ACCOUNT/REGION/ENVIRONMENT/COMPONENT
task init-backend     Create backend storage for CLOUD
task help             Show all targets
```

## CI/CD

Four GitHub Actions workflows with conditional authentication per cloud (AWS OIDC, GCP Workload Identity Federation).

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | PR / push | fmt, validate, tflint, checkov, plan (per cloud matrix) |
| `deploy.yml` | Manual | Plan or apply with cloud/account/region/env/component inputs |
| `destroy.yml` | Manual | Dev/staging only, requires confirmation |
| `drift.yml` | Scheduled | Weekday production drift detection, creates GitHub issues |

## Documentation

| Document | Description |
|----------|-------------|
| [Onboarding Guide](docs/onboarding.md) | New engineer setup, tool installation, codebase walkthrough |
| [First-time AWS Deploy](docs/first-deploy-aws.md) | Brand-new account → running EKS cluster (Identity Center, quotas, deploy order) |
| [First-time GCP Deploy](docs/first-deploy-gcp.md) | Brand-new project → running GKE cluster (APIs, Workload Identity, quotas) |
| [Architecture](docs/architecture.md) | Design rationale, dependency graph, layer breakdown, security model |
| [Operations](docs/operations.md) | Day-to-day procedures, CI/CD details, tenant management |
| [Runbooks](docs/runbooks.md) | Step-by-step procedures for common operational scenarios |
| [Troubleshooting](docs/troubleshooting.md) | Common errors and their resolutions |
| [Contributing](CONTRIBUTING.md) | Development workflow, adding components/tenants/environments |
