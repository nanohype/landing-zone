# Architecture

Design decisions, dependency graph, and structural overview of the landing-zone infrastructure.

## Design Rationale

### Why OpenTofu (not Terraform)

OpenTofu is the open-source fork of Terraform, free from licensing restrictions. The codebase requires `>= 1.10.0` and uses native S3 state locking (`use_lockfile`), removing the need for a DynamoDB lock table.

### Why Terragrunt

Terragrunt provides DRY environment management on top of OpenTofu:
- **Single provider/backend config** -- the root `root.hcl` generates `provider.tf` and `backend.tf` for every component
- **Dependency orchestration** -- `dependency` blocks in `_envcommon/aws/` wire outputs between components without hardcoding
- **Environment parity** -- same components, different inputs per environment

### Why Components (not a Monolith)

Each component has independent state, independent plan/apply, and independent blast radius. A failed `gateway` apply does not block `observability`. Components can be deployed in parallel where dependencies allow.

### Why Multi-Tenant via `for_each`

The `for_each` pattern over a `tenants` map gives each tenant isolated AWS resources while sharing the same OpenTofu module code. Adding a tenant is a map entry, not a new module call. Resources are named with the tenant key, making them easy to identify and delete. This pattern is currently used in 7 components.

## Dependency Graph

```
                    +-----------+
                    |  network  |
                    +-----+-----+
                          |
                    +-----v-----+
                    |  cluster  |
                    +-----+-----+
                          |
         +----------------+----------------+
         |                |                |
    +----v------+   +-----v------+  +------v----------+
    |  druid*   |   |  gateway   |  | cluster-addons  |
    | pipeline* |   |    rag     |  |cluster-bootstrap|
    |   llm*    |   |   mlops    |  +-----------------+
    +-----------+   | governance |
                    |observability|
                    |  secrets   |
                    +------------+

  * = also depends on network (vpc_id, private_subnet_ids)

  Standalone (no dependencies):
  backup, break-glass, service-quotas, cost, dns

  Organization layer (management account only):
  org-identity, org-security, org-compliance
  org-cost, org-networking, org-scp
```

### Dependency Details

| Component | Depends On | Receives |
|-----------|-----------|----------|
| **network** | -- | -- |
| **cluster** | network | vpc_id, private_subnet_ids, public_subnet_ids |
| **cluster-addons** | cluster | cluster_name, oidc_provider_arn, oidc_issuer |
| **cluster-bootstrap** | cluster | cluster_name, cluster_endpoint, cluster_certificate_authority_data |
| **druid** | network, cluster | vpc_id, private_subnet_ids, cluster_sg_id, oidc_provider_arn, oidc_issuer |
| **pipeline** | network, cluster | vpc_id, private_subnet_ids, cluster_sg_id, oidc_provider_arn, oidc_issuer |
| **llm** | network, cluster | vpc_id, private_subnet_ids, cluster_sg_id, oidc_provider_arn, oidc_issuer |
| **gateway** | cluster | cluster_sg_id, oidc_provider_arn, oidc_issuer |
| **rag** | cluster | cluster_sg_id, oidc_provider_arn, oidc_issuer |
| **mlops** | cluster | cluster_sg_id, oidc_provider_arn, oidc_issuer |
| **governance** | cluster | cluster_sg_id, oidc_provider_arn, oidc_issuer |
| **observability** | cluster | cluster_name |
| **secrets** | cluster | oidc_provider_arn, oidc_issuer |
| **backup** | -- | -- |
| **break-glass** | -- | -- |
| **service-quotas** | -- | -- |
| **cost** | -- | -- |
| **dns** | -- | -- |

## Layer Breakdown

### Organization Layer

Components deployed once in the management account to establish cross-account governance and shared infrastructure.

| Component | What it provisions |
|-----------|--------------------|
| **org-identity** | IAM Identity Center (SSO) -- permission sets, groups, account assignments |
| **org-security** | GuardDuty (S3/EKS/malware/RDS/Lambda), Security Hub (CIS + AWS Foundational) |
| **org-compliance** | Shared KMS, organization CloudTrail, AWS Config rules + conformance packs |
| **org-cost** | Organization budget, cost categories, anomaly detection, CUR 2.0 export |
| **org-networking** | Transit Gateway + RAM sharing, IPAM, Route53 Resolver rules |
| **org-scp** | Service Control Policies on OUs/accounts |

### Network Layer

**Component:** `network`

Provisions the network foundation for each environment:

- VPC with configurable CIDR
- Subnet tiers: public, private, intra (across AZs)
- NAT gateways (1/2/3 by environment)
- VPC endpoints (optional)
- VPC flow logs (staging + production)

### Cluster Layer

**Components:** `cluster`, `cluster-bootstrap`, `cluster-addons`

| Component | What it provisions |
|-----------|--------------------|
| **cluster** | EKS control plane, Karpenter, system node group, access entries |
| **cluster-bootstrap** | Helm-based Cilium CNI + ArgoCD bootstrap |
| **cluster-addons** | IRSA roles for Velero, OpenCost, KEDA, Argo Events/Workflows |

`cluster-bootstrap` is the GitOps boundary -- after bootstrap, ArgoCD manages in-cluster workloads from `eks-gitops`.

### Workload Layer

Seven multi-tenant components, each accepting a `var.tenants` map:

| Component | Per-Tenant Resources | Team |
|-----------|---------------------|------|
| **druid** | Aurora MySQL (Serverless v2), MSK cluster, S3 buckets, Secrets Manager, SSM parameters, IRSA | data-platform |
| **pipeline** | AWS Batch compute, S3 data lake (raw/staging/curated), Glue catalog, MSK, Step Functions, IRSA | data-platform |
| **gateway** | API Gateway v2, WAF with bot control, Cognito user pool, usage plans, IRSA | platform |
| **llm** | EFS storage, DynamoDB, SQS queues, S3 model storage, ECR, Secrets Manager, IRSA | ml-platform |
| **mlops** | DynamoDB tables, ECR repos, S3 (datasets/artifacts), SQS, IRSA | ml-platform |
| **rag** | OpenSearch Serverless, S3 document storage, DynamoDB (conversations), IRSA | ml-platform |
| **governance** | S3 audit/guardrail buckets, DynamoDB, EventBridge, IRSA | security |

### Operational Layer

| Component | Purpose | Team |
|-----------|---------|------|
| **observability** | CloudWatch alarms (CPU, memory, node count, API errors), dashboards, SNS notification topics | sre |
| **secrets** | KMS customer-managed keys + Secrets Manager + External Secrets Operator IRSA role | security |
| **backup** | AWS Backup plans with configurable schedules/retention, vault lock for production | sre |
| **break-glass** | Emergency access IAM roles with SNS alerts on assumption | security |
| **service-quotas** | CloudWatch alarms for service quota utilization | platform |
| **cost** | AWS Budgets alerts, Cost Anomaly Detection | finops |
| **dns** | Route53 zones, subdomain delegation, ACM certificates | platform |

## Environment Differentiation

| Setting | dev | staging | production |
|---------|-----|---------|------------|
| NAT gateways | 1 | 2 | 3 (HA) |
| VPC flow logs | Off | On | On |
| Cluster public API | Yes | No | No |
| System node range | 2 | 2-6 | 3-9 |
| System node disk | 50 GB | 100 GB | 100 GB |
| Cilium operator replicas | 1 | 2 | 2 |
| ArgoCD replicas | 1 | 2 | 2 |
| Druid RDS ACU range | 0.5-4 | 0.5-8 | 2-16 |
| Druid MSK | Disabled | Enabled | Enabled |
| Druid deletion protection | Off | On | On |
| Druid backup retention | 3 days | 7 days | 35 days |
| Data classification | internal | internal | confidential |

## GitOps Boundary

```
+----------------------------------+     +------------------------------+
|          landing-zone            |     |       eks-gitops         |
|          (this repo)             |     |                              |
|                                  |     |                              |
|  OpenTofu + Terragrunt           |     |  ArgoCD ApplicationSets     |
|                                  |     |                              |
|  Manages:                        |     |  Manages:                    |
|  - Cloud resources (VPC, EKS,    |     |  - Kubernetes workloads      |
|    databases, storage, IAM)      |     |  - Helm releases             |
|  - Cilium CNI (bootstrap)       |     |  - ConfigMaps, Secrets       |
|  - ArgoCD (bootstrap)           |     |  - Ingress, Services         |
|  - IRSA roles                   |     |  - CRDs, Operators           |
+----------------------------------+     +------------------------------+
              |                                       |
              |         cluster-bootstrap             |
              |<------- is the handoff point -------->|
              |                                       |
```

After `cluster-bootstrap` deploys Cilium and ArgoCD, ArgoCD watches the GitOps repo and reconciles all in-cluster resources.

## Security Model

### CI/CD Authentication

GitHub Actions assumes `AWS_ROLE_ARN` via OIDC federation -- no long-lived credentials. Each environment has its own role with a trust policy scoped to the repository.

### Pod Authentication (IRSA)

The `modules/aws/workload-identity/` module creates IAM roles for service accounts. Each role's trust policy targets the EKS cluster's OIDC provider and is scoped to a specific Kubernetes namespace and service account. Multi-tenant components create one IRSA role per tenant.

### Guardrails

The `org-scp` component attaches Service Control Policies to OUs/accounts. Guardrails prevent actions like disabling audit logging, leaving the organization, or using unapproved regions.

### Emergency Access

The `break-glass` component provisions emergency access IAM roles with SNS alerts on assumption and a configurable `max_session_duration` (default 1 hour).

### SSO / Identity

The `org-identity` component manages IAM Identity Center -- 5 permission sets (Admin, PowerUser, ReadOnly, PlatformEngineer, Developer), groups, and account assignments.

## State Management

State lives in S3 (versioned, AES-256 encrypted) with native conditional-write locking (`use_lockfile`). Buckets are named `{account_id}-{region}-tfstate` and created by `scripts/init-backend-aws.sh`; state keys follow `{environment}/{component}/terraform.tfstate`.

Each component in each environment has independent state, enabling parallel operations and isolated blast radius.

## Team Ownership

Based on `team` tags set in `_envcommon/aws/` files:

| Team | Components |
|------|-----------|
| **platform** | network, cluster, cluster-addons, cluster-bootstrap, gateway, dns, service-quotas, all org-* |
| **sre** | observability, backup |
| **security** | governance, secrets, break-glass |
| **data-platform** | druid, pipeline |
| **ml-platform** | llm, mlops, rag |
| **finops** | cost |
