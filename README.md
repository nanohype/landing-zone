# landing-zone

![OpenTofu](https://img.shields.io/badge/OpenTofu-%3E%3D1.11-blue?logo=opentofu)
![Terragrunt](https://img.shields.io/badge/Terragrunt-latest-blue?logo=terraform)
![AWS](https://img.shields.io/badge/AWS-Platform-FF9900?logo=amazonaws)
![License](https://img.shields.io/badge/License-Apache_2.0-green)

OpenTofu + Terragrunt monorepo for enterprise platform infrastructure on AWS.

**AI clients / agents start here:** [`AGENTS.md`](AGENTS.md). For the stack-wide view, see the [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md).

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  Organization Layer (management account)                              │
│  org-identity · org-security · org-compliance · org-cost              │
│  org-networking · org-scp                                             │
└─────────────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Environment Layer (development / staging / production)               │
│                                                                       │
│  ┌──────────┐    ┌──────────┐    ┌──────────────────────────────┐    │
│  │ network  │───▶│ cluster  │───▶│ druid · pipeline              │    │
│  │ (create  │    │          │───▶│ governance · observability    │    │
│  │  | adopt)│    │          │───▶│ secrets · cluster-addons      │    │
│  │          │    │          │───▶│ cluster-bootstrap             │    │
│  └──────────┘    └──────────┘    └──────────────────────────────┘    │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ agent-iam: operator IRSA role + tenant permissions boundary   │   │
│  │ (a tenant's substrate is declared in Platform.spec.datastores) │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ backup · break-glass · service-quotas · cost · dns ·          │   │
│  │ github-oidc  (standalone — no dependencies)                    │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────┐  ┌────────────────────────────────┐
│  Hub (fleet/portal control plane) │  │  Network-owner account          │
│  fleet-hub · fleet-vend ·         │  │  shared-network ──RAM──▶ adopt   │
│  fleet-unwedge · portal-hub ·     │  │  egress-network (central egress  │
│  portal-spoke · managed-monitoring│  │  hub behind the org TGW)         │
└───────────────────────────────────┘  └────────────────────────────────┘
```

**Environment hierarchy:**

```
live/aws/{account}/{region}/{environment}/{component}/terragrunt.hcl
```

**GitOps boundary:** OpenTofu deploys cloud resources + Cilium + ArgoCD. ArgoCD manages everything else via [eks-gitops](https://github.com/nanohype/eks-gitops).

## Repository Structure

```
landing-zone/
├── components/
│   └── aws/                # AWS OpenTofu root modules (one dir per component)
├── fleet/
│   └── aws/                # eks-fleet vend roots (cluster-stack, cluster-bootstrap)
├── live/
│   ├── root.hcl            # Root config (AWS provider + S3 state backend)
│   ├── _envcommon/
│   │   └── aws/            # Dependency wiring per component
│   └── aws/
│       ├── cloud.hcl
│       ├── management/           # Management account (org components)
│       ├── workload-development/ # Development account
│       ├── workload-staging/
│       ├── workload-production/
│       ├── fleet/                # Hub control plane (fleet/portal, managed-monitoring)
│       └── network/              # Network-owner account (shared-network, egress-network)
├── modules/
│   └── aws/
│       ├── workload-identity/    # EKS Pod Identity role factory
│       └── eks-vpc-endpoints/    # Private endpoint set (create-mode network + shared-network)
├── scripts/
│   └── init-backend-aws.sh
├── Taskfile.yaml
└── .tflint-aws.hcl          # TFLint config (AWS plugin)
```

## Prerequisites

- [OpenTofu](https://opentofu.org/) >= 1.11.0
- [Terragrunt](https://terragrunt.gruntwork.io/) (latest)
- [AWS CLI v2](https://aws.amazon.com/cli/)
- [TFLint](https://github.com/terraform-linters/tflint) with the AWS plugin

## Quick Start

```bash
# 1. Clone and configure
git clone <repo-url> && cd landing-zone
# Update account IDs in live/aws/{account}/account.hcl

# 2. Create backend infrastructure
./scripts/init-backend-aws.sh <account_id> <region>

# 3. Plan all development components
task plan ACCOUNT=workload-development REGION=us-east-1 ENVIRONMENT=development

# 4. Apply a single component
task apply ACCOUNT=workload-development REGION=us-east-1 ENVIRONMENT=development COMPONENT=network
```

## Task Targets

```
task fmt              Format all OpenTofu files
task fmt:check        Check formatting without modifying files
task validate         Validate all components
task lint             Run TFLint on all components
task plan             Plan for ACCOUNT/REGION/ENVIRONMENT/COMPONENT
task apply            Apply for ACCOUNT/REGION/ENVIRONMENT/COMPONENT
task init-backend     Create the S3 state backend
task help             Show all targets
```

## CI/CD

Five GitHub Actions workflows, all authenticating via AWS OIDC (`AWS_ROLE_ARN` repo variable — no long-lived credentials).

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | PR / push | placeholders, fmt, validate, tofu test, tflint, checkov, terragrunt evaluate, mock-outputs + smoke-outputs cross-checks, plan (per-component matrix) |
| `deploy.yml` | Manual | Plan or apply with account/region/env/component inputs |
| `destroy.yml` | Manual | Development/staging only, requires confirmation |
| `drift.yml` | Scheduled | Weekday production + staging drift detection, creates GitHub issues |
| `e2e.yml` | Manual | Provisions a real substrate, installs the operator, deploys a tenant via GitOps, tears down (never scheduled) |

## Documentation

| Document | Description |
|----------|-------------|
| [Onboarding Guide](docs/onboarding.md) | New engineer setup, tool installation, codebase walkthrough |
| [First-time AWS Deploy](docs/first-deploy-aws.md) | Brand-new account → running EKS cluster (Identity Center, quotas, deploy order) |
| [Architecture](docs/architecture.md) | Design rationale, dependency graph, layer breakdown, security model |
| [Threat Model](docs/threat-model.md) | STRIDE analysis per trust boundary, mitigations, residual risk |
| [Inputs Catalog](docs/inputs.md) | Every value an operator supplies (account/region/env locals, CI vars) + new-env checklist |
| [Operations](docs/operations.md) | Day-to-day procedures, CI/CD details, tenant management |
| [Runbooks](docs/runbooks.md) | Step-by-step procedures for common operational scenarios |
| [Troubleshooting](docs/troubleshooting.md) | Common errors and their resolutions |
| [Contributing](CONTRIBUTING.md) | Development workflow, adding components/tenants/environments |
