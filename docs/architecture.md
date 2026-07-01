# Architecture

Design decisions, dependency graph, and structural overview of the landing-zone infrastructure.

## Design Rationale

### Why OpenTofu (not Terraform)

OpenTofu is the open-source fork of Terraform, free from licensing restrictions. The codebase requires `>= 1.10.0` and uses native S3 state locking (`use_lockfile`), removing the need for a DynamoDB lock table.

### Why Terragrunt

Terragrunt provides DRY environment management on top of OpenTofu:
- **Single provider/backend config** -- the root `root.hcl` generates the cloud-specific `provider.tf` and `backend.tf` for every component
- **Dependency orchestration** -- `dependency` blocks in `_envcommon/{cloud}/` wire outputs between components without hardcoding
- **Environment parity** -- same components, different inputs per environment
- **Multi-cloud dispatch** -- a single root config conditionally generates the correct provider (AWS/GCP) and state backend (S3/GCS)

### Why Components (not a Monolith)

Each component has independent state, independent plan/apply, and independent blast radius. A failed `gateway` apply does not block `observability`. Components can be deployed in parallel where dependencies allow.

### Why Multi-Tenant via `for_each`

The `for_each` pattern over a `tenants` map gives each tenant isolated cloud resources while sharing the same OpenTofu module code. Adding a tenant is a map entry, not a new module call. Resources are named with the tenant key, making them easy to identify and delete. This pattern is currently used in 7 AWS components.

## Dependency Graph

The core dependency chain applies to both clouds. AWS has additional workload-layer components.

### AWS (24 components)

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

### GCP (17 components)

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
    +----v----------+ +---v-----------+ +--v--------------+
    |cluster-addons | |cluster-bootstrap| | observability  |
    +---------------+ +----------------+ |   secrets      |
                                         +----------------+

  Standalone (no dependencies):
  backup, break-glass, service-quotas, cost, dns

  Organization layer:
  org-identity, org-security, org-compliance
  org-cost, org-networking, org-policy
```

### Dependency Details (AWS)

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

GCP follows the same `network -> cluster -> {cluster-addons, cluster-bootstrap, observability, secrets}` chain. Standalone components have no dependencies on either cloud.

## Layer Breakdown

### Organization Layer

Components deployed once in the management/org account to establish cross-account governance and shared infrastructure.

| Component | AWS | GCP |
|-----------|-----|-----|
| **org-identity** | IAM Identity Center (SSO) -- permission sets, groups, account assignments | Cloud Identity groups, IAM bindings across projects |
| **org-security** | GuardDuty (S3/EKS/malware/RDS/Lambda), Security Hub (CIS + AWS Foundational) | Security Command Center, Web Security Scanner |
| **org-compliance** | Shared KMS, organization CloudTrail, AWS Config rules + conformance packs | Organization audit logging, Cloud Asset Inventory, access transparency logs |
| **org-cost** | Organization budget, cost categories, anomaly detection, CUR 2.0 export | Billing budgets, BigQuery billing export, commitment analysis |
| **org-networking** | Transit Gateway + RAM sharing, IPAM, Route53 Resolver rules | Shared VPC, VPC peering, Cloud DNS policies |
| **org-scp / org-policy** | Service Control Policies on OUs/accounts | Organization Policies (constraints on folders/projects) |

### Network Layer

**Component:** `network`

Provisions the network foundation for each environment:

| Feature | AWS | GCP |
|---------|-----|-----|
| Network | VPC with configurable CIDR | VPC network with subnets |
| Subnet tiers | public, private, intra (across AZs) | public, private (across zones) |
| NAT | NAT gateways (1/2/3 by env) | Cloud NAT (1/2/3 by env) |
| Service access | VPC endpoints (optional) | Private Google Access, Private Service Connect |
| Flow logs | VPC flow logs (staging + prod) | VPC Flow Logs (staging + prod) |

### Cluster Layer

**Components:** `cluster`, `cluster-bootstrap`, `cluster-addons`

| Feature | AWS | GCP |
|---------|-----|-----|
| **cluster** | EKS control plane, Karpenter, system node group, access entries | GKE Standard/Autopilot, node pools, workload identity |
| **cluster-bootstrap** | Helm-based Cilium CNI + ArgoCD bootstrap | Cilium CNI + ArgoCD bootstrap |
| **cluster-addons** | IRSA roles for Velero, OpenCost, KEDA, Argo Events/Workflows | Workload Identity bindings for cluster tools |

`cluster-bootstrap` is the GitOps boundary -- after bootstrap, ArgoCD manages in-cluster workloads from `eks-gitops`.

### Workload Layer (AWS only)

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

Components shared across both clouds (implementations differ per cloud):

| Component | Purpose | Team |
|-----------|---------|------|
| **observability** | Monitoring alarms/alerts, dashboards, notification channels (CloudWatch / Cloud Monitoring) | sre |
| **secrets** | Encryption keys + secrets store + External Secrets Operator workload identity (KMS+Secrets Manager / Cloud KMS+Secret Manager) | security |
| **backup** | Backup plans with configurable schedules/retention, vault lock for production (AWS Backup / GCP snapshots) | sre |
| **break-glass** | Emergency access roles with alerts on assumption (IAM roles / privileged Google SA / PIM-eligible roles) | security |
| **service-quotas** | Alarms for cloud service quota utilization (CloudWatch / Cloud Monitoring) | platform |
| **cost** | Budget alerts, anomaly detection (AWS Budgets / GCP Billing) | finops |
| **dns** | DNS zones, subdomain delegation, certificates (Route53+ACM / Cloud DNS+Certificate Manager) | platform |

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
| Druid RDS ACU range (AWS) | 0.5-4 | 0.5-8 | 2-16 |
| Druid MSK (AWS) | Disabled | Enabled | Enabled |
| Druid deletion protection (AWS) | Off | On | On |
| Druid backup retention (AWS) | 3 days | 7 days | 35 days |
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
|  - Cloud resources (VPC/VNet,    |     |  - Kubernetes workloads      |
|    EKS/GKE, databases,          |     |  - Helm releases             |
|    storage, IAM, etc.)           |     |  - ConfigMaps, Secrets       |
|  - Cilium CNI (bootstrap)       |     |  - Ingress, Services         |
|  - ArgoCD (bootstrap)           |     |  - CRDs, Operators           |
|  - Workload identity roles      |     |                              |
+----------------------------------+     +------------------------------+
              |                                       |
              |         cluster-bootstrap             |
              |<------- is the handoff point -------->|
              |                                       |
```

After `cluster-bootstrap` deploys Cilium and ArgoCD, ArgoCD watches the GitOps repo and reconciles all in-cluster resources.

## Security Model

### CI/CD Authentication

| Cloud | Mechanism | Details |
|-------|-----------|---------|
| AWS | OIDC federation | GitHub Actions assumes `AWS_ROLE_ARN` via OIDC -- no long-lived credentials. Trust policy scoped to the repository. |
| GCP | Workload Identity Federation | GitHub Actions exchanges OIDC token for short-lived GCP credentials via a Workload Identity Pool. No service account keys. |

Each environment has its own role/identity with a trust policy scoped to the repository.

### Pod Authentication (Workload Identity)

| Cloud | Mechanism | Module |
|-------|-----------|--------|
| AWS | IRSA (IAM Roles for Service Accounts) | `modules/aws/workload-identity/` |
| GCP | GKE Workload Identity (KSA-to-GSA binding) | `modules/gcp/workload-identity/` |

Each module creates a cloud IAM identity scoped to a specific Kubernetes namespace and service account. Multi-tenant AWS components create one IRSA role per tenant.

### Guardrails

| Cloud | Mechanism | Component |
|-------|-----------|-----------|
| AWS | Service Control Policies (SCPs) on OUs/accounts | `org-scp` |
| GCP | Organization Policy constraints on folders/projects | `org-policy` |

Guardrails prevent actions like disabling audit logging, leaving the organization, or using unapproved regions.

### Emergency Access

The `break-glass` component provisions emergency access roles per cloud:

| Cloud | Mechanism |
|-------|-----------|
| AWS | IAM roles with SNS alerts on assumption, configurable `max_session_duration` (default 1 hour) |
| GCP | Privileged Google service accounts with audit logging, time-bound access |

### SSO / Identity

The `org-identity` component manages identity and access per cloud:

| Cloud | Mechanism |
|-------|-----------|
| AWS | IAM Identity Center -- 5 permission sets (Admin, PowerUser, ReadOnly, PlatformEngineer, Developer), groups, account assignments |
| GCP | Cloud Identity groups, project-level IAM bindings, custom roles |

## State Management

| Cloud | Backend | Locking | Bucket/Container Naming | Init Script |
|-------|---------|---------|------------------------|-------------|
| AWS | S3 (versioned, AES-256 encrypted) | Native conditional writes (`use_lockfile`) | `{account_id}-{region}-tfstate` | `scripts/init-backend-aws.sh` |
| GCP | GCS (versioned) | Native GCS locking | `{project_id}-{region}-tfstate` | `scripts/init-backend-gcp.sh` |

Key convention: `{environment}/{component}/terraform.tfstate` (AWS) or `{environment}/{component}/` prefix (GCP).

Each component in each environment has independent state, enabling parallel operations and isolated blast radius.

## Team Ownership

Based on `team` tags set in `_envcommon/{cloud}/` files:

| Team | Components |
|------|-----------|
| **platform** | network, cluster, cluster-addons, cluster-bootstrap, gateway*, dns, service-quotas, all org-* |
| **sre** | observability, backup |
| **security** | governance*, secrets, break-glass |
| **data-platform** | druid*, pipeline* |
| **ml-platform** | llm*, mlops*, rag* |
| **finops** | cost |

\* = AWS-only component
