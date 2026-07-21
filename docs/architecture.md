# Architecture

Design decisions, dependency graph, and structural overview of the landing-zone infrastructure.

## Design Rationale

### Why OpenTofu (not Terraform)

OpenTofu is the open-source fork of Terraform, free from licensing restrictions. The codebase requires `>= 1.11.0` and uses native S3 state locking (`use_lockfile`), removing the need for a DynamoDB lock table.

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
  backup, break-glass, service-quotas, cost, dns, github-oidc

  Organization layer (management account only):
  org-identity, org-security, org-compliance
  org-cost, org-networking, org-scp

  Agent-platform subsystem (depends on cluster):
  agent-iam -> the four *-platform tenant substrates
  (competitive-intelligence, digest-pipeline,
   incident-response, slack-knowledge-bot)

  Fleet / portal subsystem (cross-account, hub-side):
  fleet-hub -> fleet-vend; portal-hub -> portal-spoke,
  fleet-unwedge; managed-monitoring (AMP/AMG on the hub)

  Network-owner account (cross-account adopt topology):
  shared-network -> workload network (adopt mode, via RAM);
  egress-network (central egress hub behind the org TGW)
```

### Dependency Details

| Component | Depends On | Receives |
|-----------|-----------|----------|
| **network** | -- | -- |
| **shared-network** | -- (org IPAM pool discovered by tag, cross-account via RAM) | -- |
| **egress-network** | -- (org TGW RAM-shared in; `org-networking` owns the static default route) | -- |
| **cluster** | network | vpc_id, private_subnet_ids, public_subnet_ids |
| **cluster-addons** | cluster | cluster_name |
| **cluster-bootstrap** | cluster | cluster_name, cluster_endpoint, cluster_certificate_authority_data |
| **druid** | network, cluster | vpc_id, private_subnet_ids, cluster_sg_id, cluster_name |
| **pipeline** | network, cluster | vpc_id, private_subnet_ids, cluster_sg_id, cluster_name |
| **llm** | network, cluster | vpc_id, private_subnet_ids, cluster_sg_id, cluster_name |
| **gateway** | cluster | cluster_sg_id, cluster_name |
| **rag** | cluster | cluster_sg_id, cluster_name |
| **mlops** | cluster | cluster_sg_id, cluster_name |
| **governance** | cluster | cluster_sg_id, cluster_name |
| **observability** | cluster | cluster_name |
| **secrets** | cluster | cluster_name |
| **agent-iam** | cluster | oidc_provider_arn, oidc_issuer, operator_permissions_boundary_arn (optional) |
| **competitive-intelligence-platform** | network, cluster, agent-iam | vpc_id, private_subnet_ids, cluster_sg_id, cluster_name (+ resolves the operator-minted tenant role) |
| **digest-pipeline-platform** | network, cluster, agent-iam | vpc_id, private_subnet_ids, cluster_sg_id, cluster_name, ses_sending_domain |
| **incident-response-platform** | cluster, agent-iam | cluster_name (no VPC — no in-VPC data plane) |
| **slack-knowledge-bot-platform** | network, cluster, agent-iam | vpc_id, private_subnet_ids, cluster_sg_id, cluster_name |
| **fleet-hub** | cluster | oidc_provider_arn, oidc_issuer |
| **fleet-vend** | fleet-hub | hub_role_arn, external_id |
| **fleet-unwedge** | portal-hub | portal_role_arn, external_id |
| **portal-hub** | cluster | oidc_provider_arn, oidc_issuer, state_bucket_name |
| **portal-spoke** | portal-hub | portal_hub_role_arn, external_id |
| **managed-monitoring** | cluster | cluster_name |
| **github-oidc** | -- | -- |
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

- VPC with configurable CIDR (literal or IPAM-drawn), `create` or `adopt` mode
- Subnet tiers: public, private (across AZs)
- NAT gateways (1/2/3 by environment), or centralized egress via the transit gateway
- VPC endpoints (optional, via the shared `eks-vpc-endpoints` module)
- VPC flow logs (staging + production)

In `adopt` mode the component builds nothing — it resolves an existing VPC and subnet IDs
(same-account or cross-account via RAM) and re-exports them through the same outputs, with a
consumer-side preflight that fails at `plan` if the adopted network is missing the S3 gateway
route or a live default egress route.

### Shared Network Layer

**Component:** `shared-network` (network-owner account)

The owner side of the cross-account `adopt` topology. A central network-owner account runs
one shared VPC per environment and RAM-shares its subnets to the workload accounts that adopt
them — the seam that lets a workload cluster participate in a VPC it does not own:

- VPC with an IPAM-drawn CIDR (from the org env sub-pool, discovered by tag)
- the full private endpoint set (owner-run — a participant cannot endpoint a foreign VPC)
- owner-run egress (local NAT or a transit gateway to a central egress hub)
- ELB role tags only, deliberately no per-cluster ownership tag (a shared VPC binds to no
  single cluster)
- RAM share of the subnets to `consumer_account_ids`, plus owner-side contract `check` blocks

The workload account then runs `network` in `adopt` mode against the shared subnet IDs and a
`cluster` with `stamp_subnet_tags = false`. See `components/aws/shared-network/README.md` for
the full owner↔consumer contract.

### Egress Network Layer

**Component:** `egress-network` (network-owner account, hub slot)

The central-egress hub — the far side of `centralized_egress`. When a spoke VPC (a create-mode
`network` or a `shared-network` owner VPC) sets `centralized_egress = true`, it drops local NAT
and points its private default route (`0.0.0.0/0`) at the org transit gateway. This hub
terminates that traffic and carries it to the internet: a small dedicated-CIDR VPC with NAT
gateways, a cross-account TGW attachment, and the return route (`spoke_supernet_cidr → TGW`).

Responsibility is split: this participant-side component builds the VPC, NAT, and attachment
and publishes `tgw_attachment_id`; the static `0.0.0.0/0` route in the TGW's route table is
owned by `org-networking` (a TGW participant cannot write the shared TGW's route tables). There
is exactly one egress hub per transit gateway — the org runs a single TGW, so a single hub
serves every environment, which means development/staging/production share its NAT source IPs
and port capacity. See `components/aws/egress-network/README.md` for the full path trace and
the shared-hub blast-radius discussion.

### Cluster Layer

**Components:** `cluster`, `cluster-bootstrap`, `cluster-addons`

| Component | What it provisions |
|-----------|--------------------|
| **cluster** | EKS control plane, Karpenter, system node group, access entries |
| **cluster-bootstrap** | Helm-based Cilium CNI + ArgoCD bootstrap |
| **cluster-addons** | Pod Identity roles for Velero, OpenCost, KEDA, Argo Events/Workflows |

`cluster-bootstrap` is the GitOps boundary -- after bootstrap, ArgoCD manages in-cluster workloads from `eks-gitops`.

### Workload Layer

Seven multi-tenant components, each accepting a `var.tenants` map:

| Component | Per-Tenant Resources | Team |
|-----------|---------------------|------|
| **druid** | Aurora MySQL (Serverless v2), MSK cluster, S3 buckets, Secrets Manager, SSM parameters, Pod Identity roles | data-platform |
| **pipeline** | AWS Batch compute, S3 data lake (raw/staging/curated), Glue catalog, MSK, Step Functions, Pod Identity roles | data-platform |
| **gateway** | API Gateway v2, WAF with bot control, Cognito user pool, usage plans, Pod Identity roles | platform |
| **llm** | EFS storage, DynamoDB, SQS queues, S3 model storage, ECR, Secrets Manager, Pod Identity roles | ml-platform |
| **mlops** | DynamoDB tables, ECR repos, S3 (datasets/artifacts), SQS, Pod Identity roles | ml-platform |
| **rag** | OpenSearch Serverless, S3 document storage, DynamoDB (conversations), Pod Identity roles | ml-platform |
| **governance** | S3 audit/guardrail buckets, DynamoDB, EventBridge, Pod Identity roles | security |

### Operational Layer

| Component | Purpose | Team |
|-----------|---------|------|
| **observability** | CloudWatch alarms (CPU, memory, node count, API errors), dashboards, SNS notification topics | sre |
| **secrets** | KMS customer-managed keys + Secrets Manager (External Secrets Operator reads them with a `cluster-addons` Pod Identity role) | security |
| **backup** | AWS Backup plans with configurable schedules/retention, vault lock for production | sre |
| **break-glass** | Emergency access IAM roles with SNS alerts on assumption | security |
| **service-quotas** | CloudWatch alarms for service quota utilization | platform |
| **cost** | AWS Budgets alerts, Cost Anomaly Detection | finops |
| **dns** | Route53 zones, subdomain delegation, ACM certificates | platform |
| **github-oidc** | GitHub Actions OIDC provider + repo-scoped (`repo:<org>/<repo>:*`) deploy role — no long-lived keys | platform |
| **managed-monitoring** | Amazon Managed Prometheus + Amazon Managed Grafana (SSO role associations, AMP/CloudWatch read), Grafana URL/AMP endpoint published to SSM. Deployed on the hub. | *(required input)* |

### Agent-Platform Layer

The IAM + storage substrate the `eks-agent-platform` operator runs on, plus the
per-app tenant substrates it binds. `agent-iam` mints the operator role and the
tenant permissions boundary; each `*-platform` component provisions one tenant's
AWS resources and attaches an app-access policy to the operator-minted tenant
role via **EKS Pod Identity** (not raw IRSA).

| Component | What it provisions | Team |
|-----------|--------------------|------|
| **agent-iam** | Operator IRSA role (mints tenant roles under `/eks-agent-platform/tenants/`, boundary-gated), tenant permissions boundary + baseline policy, model-artifacts + eval-reports S3 buckets, operator SSM parameters | platform |
| **competitive-intelligence-platform** | Aurora Serverless v2 (Postgres + pgvector), app-secrets, app-access policy bound via Pod Identity | strategy |
| **digest-pipeline-platform** | Aurora Serverless v2, voice-baseline + raw-aggregations S3 buckets, SESv2 sending identity + config set, app-access policy | growth |
| **incident-response-platform** | DynamoDB (incidents/audit/identity-cache), SQS FIFO queues + DLQs, S3 audit archive, EventBridge Scheduler group + role, app-access policy | reliability |
| **slack-knowledge-bot-platform** | KMS (token envelope), DynamoDB (tokens/audit/identity-cache), ElastiCache Redis, Aurora Serverless v2 (pgvector), SQS FIFO + DLQ, S3 audit archive, app-access policy | workplace |

### Fleet & Portal Layer

Cross-account, hub-side subsystems for vending and reaching fleet clusters. Roles
are path-scoped to `/eks-fleet/` and capped by permissions boundaries; the vend
role's `CreateRole` is gated on the boundary condition (see the [Threat Model](threat-model.md), §5).

| Component | What it provisions | Team |
|-----------|--------------------|------|
| **fleet-hub** | Hub-side `eks-fleet-crossplane` IRSA role + the S3 bucket holding vended clusters' OpenTofu state; publishes `hub_permissions_boundary_arn` to SSM | platform |
| **fleet-vend** | Cross-account role the hub assumes to provision a spoke cluster; permissions boundary + path-scoped, `iam:PermissionsBoundary`-conditioned role creation | platform |
| **fleet-unwedge** | Cross-account, delete-only break-glass role (tag-conditioned to `ProvisionedBy=eks-fleet`) that portal assumes to tear down a wedged vend | platform |
| **portal-hub** | Portal worker IRSA role (assumes portal-spoke roles cross-account) + portal OpenTofu state bucket + boundary | platform |
| **portal-spoke** | Per-account read-only role (`eks:Describe*/List*`) the portal worker assumes from the hub, ExternalId-gated | platform |

> **Status:** `fleet-hub` and `managed-monitoring` are wired into the
> `live/aws/fleet/.../hub/` tree. `fleet-vend` is the spoke-side role provisioned
> per-account by the fleet factory, so it is intentionally not in the static
> `live/` tree. `portal-hub`, `portal-spoke`, and `fleet-unwedge` (the "portal
> triangle") are authored and CI-validated but not yet wired into any `live/`
> environment — they have no live inputs supplied yet.

## Environment Differentiation

| Setting | development | staging | production |
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
|  - Pod Identity roles           |     |  - CRDs, Operators           |
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

### Pod Authentication (EKS Pod Identity)

The `modules/aws/workload-identity/` module creates IAM roles for service accounts using **EKS Pod Identity**: each role's trust policy targets `pods.eks.amazonaws.com` (not an OIDC provider) and is bound to an exact (cluster, namespace, service-account) through an EKS Pod Identity association. A `tofu test` gate asserts the trust stays Pod-Identity-only. Every in-cluster workload role is minted this way, and multi-tenant components mint one role per tenant. Web-identity (OIDC) trust is reserved for the roles assumed from outside the cluster — the agent-platform operator (`agent-iam`), `fleet-hub`, `portal-hub`, and GitHub Actions CI federation. See the [Threat Model](threat-model.md) for the reasoning.

### Guardrails

The `org-scp` component attaches Service Control Policies to OUs/accounts. Guardrails prevent actions like disabling audit logging, leaving the organization, or using unapproved regions.

### Emergency Access

The `break-glass` component provisions emergency access IAM roles with SNS alerts on assumption and a configurable `max_session_duration` (default 1 hour).

### SSO / Identity

The `org-identity` component manages IAM Identity Center -- 5 permission sets (Admin, PowerUser, ReadOnly, PlatformEngineer, Developer), groups, and account assignments.

## State Management

State lives in S3 (versioned, AES-256 encrypted) with native conditional-write locking (`use_lockfile`). Buckets are named `{account_id}-{region}-tfstate` and created by `scripts/init-backend-aws.sh`; state keys follow `{environment}/{component}/terraform.tfstate`.

Each component in each environment has independent state, enabling parallel operations and isolated blast radius.

## SSM Parameter Namespaces

Components publish discovery facts (IDs, ARNs, bucket names — never secrets) to SSM Parameter
Store. Four prefix families coexist, and the prefix records **who reads the parameter**, not
which component wrote it:

| Prefix | Purpose | Writers |
|--------|---------|---------|
| `/platform/<env>/<component>/*` | owner-account metadata and audit — same-account reads by that account's own automation, not a cross-account hand-off | `org-identity`, `org-security`, `org-compliance`, `org-cost`, `org-networking`, `org-scp`, `cost`, `secrets`, `shared-network` |
| `/eks-agent-platform/<cluster-or-env>/<component>/*` | the cluster-consumer contract surface — `cluster-bootstrap` reads these and stamps them onto the ArgoCD cluster registration Secret's annotations, where the `eks-agent-platform` operator and the `eks-gitops` addons consume them | `managed-monitoring`, `dns`, `cluster-addons`, `agent-iam`/eval-runtime |
| `/<env>/<component>/*` | standalone operational components that predate the `/platform/` convention | `break-glass`, `backup`, `service-quotas` |
| `/aws/*` | AWS-reserved paths the repo names within or reads — CloudWatch log-group names (flow logs, CloudTrail, API Gateway) and the public Ubuntu AMI parameter — following AWS's own conventions, not a landing-zone namespace | (log groups; AMI data lookups) |

The split is intentional for three of the four. `/eks-agent-platform/*` is named for the
**consumer** (the operator's API group / domain) precisely so it forms a stable contract the
cluster reads regardless of which landing-zone component produced the value — decoupling the
producer from the reader is the point. `/platform/*` is the generic owner/org metadata
namespace, read only inside the producing account. `/aws/*` is not ours to name.

The one genuine inconsistency is the bare `/<env>/*` family (`break-glass`, `backup`,
`service-quotas`): those three could sit under `/platform/<env>/<component>/*` like their
siblings. It is cosmetic, not a defect — nothing reads them through a hardcoded `/platform/`
path, so the bare prefix breaks nothing; normalizing it is a low-priority cleanup, not a fix.

## Team Ownership

Owning team per component. Most components take their `team` value from the
`_envcommon/aws/` wiring; the four `*-platform` components are the exception —
their `team` is a per-component `variables.tf` default (each app is owned by a
different product team), not set in `_envcommon`.

| Team | Components |
|------|-----------|
| **platform** | network, cluster, cluster-addons, cluster-bootstrap, gateway, dns, service-quotas, github-oidc, agent-iam, fleet-hub, fleet-vend, fleet-unwedge, portal-hub, portal-spoke, all org-* |
| **sre** | observability, backup |
| **security** | governance, secrets, break-glass |
| **data-platform** | druid, pipeline |
| **ml-platform** | llm, mlops, rag |
| **strategy** | competitive-intelligence-platform |
| **growth** | digest-pipeline-platform |
| **reliability** | incident-response-platform |
| **workplace** | slack-knowledge-bot-platform |
| **finops** | cost |
| *(required input)* | managed-monitoring — no `team` default; the caller must supply one |
