# Onboarding Guide

Welcome to landing-zone. This guide gets you from zero to your first `plan` output.

## What This Repo Does

This repo provisions and manages the platform's AWS infrastructure: networking, EKS clusters, databases, queues, storage, IAM, monitoring, and cost controls. It uses OpenTofu for resource definitions and Terragrunt for environment orchestration.

**What it does NOT do:** in-cluster workloads (Kubernetes deployments, Helm releases beyond bootstrap). Those are managed by ArgoCD via the [eks-gitops](https://github.com/nanohype/eks-gitops) repo.

## Tool Installation

| Tool | Version | Install |
|------|---------|---------|
| [OpenTofu](https://opentofu.org/docs/intro/install/) | >= 1.10.0 | `brew install opentofu` |
| [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) | latest | `brew install terragrunt` |
| [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | `brew install awscli` |
| [TFLint](https://github.com/terraform-linters/tflint) | latest | `brew install tflint` |
| TFLint AWS plugin | 0.34.0 | `tflint --init -c .tflint-aws.hcl` |

## Cloud Access

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

CI uses GitHub OIDC federation -- no long-lived credentials.

## Verify Setup

Run the local validation suite -- no cloud credentials needed:

```bash
task fmt:check && task validate && task lint
```

All three should pass. If `tflint` fails, make sure you ran `tflint --init -c .tflint-aws.hcl` to install the plugin.

## Your First Plan

```bash
task plan ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=network
```

This runs `terragrunt plan` for the network component in dev. You need valid AWS credentials for this step.

## Codebase Walkthrough

### `components/`

OpenTofu root modules under `components/aws/`. Each is self-contained with `main.tf`, `variables.tf`, `outputs.tf`, and `versions.tf`. The seven multi-tenant components also have a `modules/tenant/` sub-module.

Components define **what** to create. They are environment-agnostic -- no hardcoded account IDs, regions, or environment names.

### `live/`

Terragrunt configuration that wires components to environments.

- **`root.hcl`** (root) -- generates the AWS provider with default tags and configures the S3 state backend. Every environment inherits this.
- **`_envcommon/aws/{name}.hcl`** -- one per component. Declares dependencies (which other components' outputs this one needs) and shared inputs.
- **`aws/{account}/{region}/{env}/env.hcl`** -- environment-specific locals (identifiers, cost center, business unit, data classification, compliance, repository).
- **`aws/{account}/{region}/{env}/{component}/terragrunt.hcl`** -- per-environment overrides (e.g., node counts, feature toggles, tenant maps).

### `modules/`

Shared sub-modules used across components:

- **`aws/workload-identity/`** -- IAM Roles for Service Accounts (IRSA) factory. Creates an IAM role with OIDC trust policy scoped to a specific Kubernetes namespace and service account.

### Key Files

- **`Taskfile.yaml`** -- task automation (`fmt`, `validate`, `lint`, `plan`, `apply`)
- **`.tflint-aws.hcl`** -- TFLint configuration with the AWS plugin
- **`scripts/init-backend-aws.sh`** -- creates the S3 state backend

## Key Concepts

### Workload Identity (IRSA)

Pods assume IAM roles via OIDC federation. The `modules/aws/workload-identity/` module scopes each role to a specific namespace and service account.

### Multi-Tenant Pattern

Seven components (`druid`, `pipeline`, `gateway`, `llm`, `mlops`, `rag`, `governance`) accept a `var.tenants` map. Each key becomes a separate set of AWS resources via `for_each`. Tenants are isolated at the resource level (separate databases, buckets, queues, IAM roles).

### GitOps Boundary

OpenTofu manages cloud resources plus the initial bootstrap of Cilium (CNI) and ArgoCD (via `cluster-bootstrap`). Once ArgoCD is running, it takes over all in-cluster workload management from the `eks-gitops` repo.

### Default Tags

The root `root.hcl` injects metadata on every resource via the provider's `default_tags`. Components must not duplicate these.

### State Management

State lives in S3 with native conditional-write locking (`use_lockfile`). Buckets are named `{account_id}-{region}-tfstate`, versioned, and encrypted. Each component in each environment has its own state file.

## Next Steps

- [First-time AWS Deploy](first-deploy-aws.md) -- account setup → running cluster (IAM Identity Center, EKS, AMP/AMG)
- [Architecture](architecture.md) -- design rationale, dependency graph, security model
- [Operations](operations.md) -- day-to-day procedures, CI/CD details
- [Runbooks](runbooks.md) -- incident procedures (drift, state locks, break-glass)
- [Troubleshooting](troubleshooting.md) -- common errors and fixes
