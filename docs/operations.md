# Operations

Day-to-day procedures for operating the landing-zone infrastructure across AWS, GCP, and Azure.

## Planning and Applying

### Single Component

```bash
# AWS
make plan CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=network
make apply CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=network

# GCP
make plan CLOUD=gcp ACCOUNT=workload-dev REGION=us-central1 ENVIRONMENT=dev COMPONENT=network
make apply CLOUD=gcp ACCOUNT=workload-dev REGION=us-central1 ENVIRONMENT=dev COMPONENT=network

# Azure
make plan CLOUD=azure ACCOUNT=workload-dev REGION=westus2 ENVIRONMENT=dev COMPONENT=network
make apply CLOUD=azure ACCOUNT=workload-dev REGION=westus2 ENVIRONMENT=dev COMPONENT=network
```

### All Components in an Environment

```bash
make plan CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev
make apply CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev
```

Terragrunt resolves the dependency graph and runs components in the correct order.

### Organization Components (AWS)

```bash
make plan CLOUD=aws ACCOUNT=management REGION=us-west-2 ENVIRONMENT=org COMPONENT=org-identity
make apply CLOUD=aws ACCOUNT=management REGION=us-west-2 ENVIRONMENT=org COMPONENT=org-identity
```

## Deployment Order

For a from-scratch deployment, components must be applied in dependency order. The core dependency chain (`network -> cluster -> workloads + standalone`) applies to all three clouds.

### AWS Organization (run first, once)

```
1. org-scp
2. org-identity
3. org-security
4. org-compliance
5. org-cost
6. org-networking
```

Order within the org layer is flexible -- these components have no inter-dependencies. GCP and Azure have equivalent org-level components (`org-policy`, `org-identity`, `org-security`, `org-compliance`, `org-cost`, `org-networking`).

### AWS Per Environment (dev -> staging -> production)

```
1. network
2. cluster
3. cluster-bootstrap          (depends on cluster)
4. cluster-addons             (depends on cluster)
5. secrets                    (depends on cluster)
6. observability              (depends on cluster)
7. druid                      (depends on network + cluster)
8. pipeline                   (depends on network + cluster)
9. llm                        (depends on network + cluster)
10. gateway                   (depends on cluster)
11. rag                       (depends on cluster)
12. mlops                     (depends on cluster)
13. governance                (depends on cluster)
14. cost                      (standalone)
15. dns                       (standalone)
16. backup                    (standalone)
17. break-glass               (standalone)
18. service-quotas            (standalone)
```

Steps 3-13 can run in parallel within their dependency tier. Steps 14-18 can run at any time.

### GCP / Azure Per Environment

```
1. network
2. cluster
3. cluster-bootstrap          (depends on cluster)
4. cluster-addons             (depends on cluster)
5. secrets                    (depends on cluster)
6. observability              (depends on cluster)
7. cost                       (standalone)
8. dns                       (standalone)
9. backup                    (standalone)
10. break-glass               (standalone)
11. service-quotas            (standalone)
```

GCP and Azure have 11 workload components (no multi-tenant components). Steps 3-6 can run in parallel. Steps 7-11 can run at any time.

Using `make apply CLOUD=<cloud> ACCOUNT=<account> REGION=<region> ENVIRONMENT=<env>` (without `COMPONENT`) runs `terragrunt run --all -- apply`, which handles ordering automatically.

## CI/CD Workflows

### ci.yml -- Pull Request Validation

**Triggers:** PRs to `main`, pushes to `main`.

| Job | Details |
|-----|---------|
| **fmt** | Runs `tofu fmt -check -recursive` on `components/` and `modules/`. Fails if any file is unformatted. |
| **validate** | Matrix of all components per cloud (24 AWS, 17 GCP, 17 Azure). Runs `tofu init -backend=false` then `tofu validate`. Catches syntax errors and missing variable definitions. |
| **tflint** | Runs TFLint recursively per cloud with the appropriate plugin (`.tflint-aws.hcl`, `.tflint-gcp.hcl`, `.tflint-azure.hcl`). Enforces naming conventions, documented variables/outputs, and cloud-specific rules. |
| **checkov** | Security scan on `components/`. Skips `CKV_AWS_144` (cross-region replication) and `CKV_AWS_145` (KMS encryption). |
| **plan** | PRs only. Matrix across clouds and environments. Runs `terragrunt plan` to show what would change. |

### deploy.yml -- Manual Deploy

**Trigger:** Workflow dispatch (manual).

**Inputs:**
- `cloud` -- aws, gcp, or azure
- `account` -- target account/project/subscription alias
- `region` -- target region
- `environment` -- dev, staging, or production
- `component` -- specific component name or "all"
- `action` -- plan or apply

Uses GitHub environment protection rules -- production requires approval. When `component=all`, runs `terragrunt run --all -- <action>`. Otherwise targets the specific component directory.

### destroy.yml -- Manual Destroy

**Trigger:** Workflow dispatch (manual).

**Inputs:**
- `cloud` -- aws, gcp, or azure
- `environment` -- dev or staging only (production excluded)
- `component` -- specific component name or "all"
- `confirm` -- must exactly match the environment name

The confirmation guard (`confirm == environment`) prevents accidental destroys. Runs `terragrunt destroy` or `terragrunt run --all -- destroy`.

### drift.yml -- Drift Detection

**Trigger:** Cron schedule, 6 AM UTC Monday-Friday. Also supports manual dispatch.

**Scope:** Currently AWS production only, 8 components: `network`, `cluster`, `cluster-addons`, `cluster-bootstrap`, `dns`, `cost`, `observability`, `secrets`. GCP and Azure drift detection is planned for a future release.

**Behavior:** Runs `terragrunt plan -detailed-exitcode` for each component. Exit code 2 means changes detected (drift). When drift is found, creates or updates a GitHub issue labelled `drift` with the plan output.

**Response:** See [RB-001: Drift Detected](runbooks.md#rb-001-drift-detected) in the runbooks.

## Tenant Management

Multi-tenant components are currently AWS-only (`druid`, `pipeline`, `gateway`, `llm`, `mlops`, `rag`, `governance`).

### Adding a Tenant

1. Identify the component(s) the tenant needs (e.g., `druid`, `pipeline`, `gateway`)
2. Edit the environment's `terragrunt.hcl` for each component
3. Add an entry to the `tenants` map:
   ```hcl
   tenants = {
     new-tenant = {
       # see variables.tf for the full schema and defaults
       deletion_protection = true
     }
   }
   ```
4. Plan to verify: `make plan CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=<component>`
5. Apply: `make apply CLOUD=aws ACCOUNT=workload-dev REGION=us-west-2 ENVIRONMENT=dev COMPONENT=<component>`

### Removing a Tenant

1. Set `deletion_protection = false` and apply (for components that support it)
2. Remove the tenant entry from the `tenants` map
3. Plan and verify the destroy actions
4. Apply

### Tenant Configuration Reference

Each multi-tenant component has different tenant fields. Check the `variables.tf` in the component for the full schema:

| Component | Key Tenant Fields |
|-----------|------------------|
| **druid** | `rds_min_acu`, `rds_max_acu`, `rds_backup_days`, `msk_enabled`, `deletion_protection` |
| **pipeline** | `batch_enabled`, `step_functions_enabled`, `msk_enabled`, `batch_max_vcpus`, `deletion_protection` |
| **gateway** | `waf_enabled`, `cognito_enabled`, `waf_rate_limit`, `throttle_rate/burst/quota` |
| **llm** | `efs_performance_mode`, `sqs_visibility_timeout`, `dynamodb_pitr`, `deletion_protection` |
| **mlops** | `ecr_enabled`, `point_in_time_recovery`, `run_ttl_days`, `deletion_protection` |
| **rag** | `opensearch_standby_replicas`, `opensearch_dimensions`, `document_versioned`, `deletion_protection` |
| **governance** | `object_lock_enabled`, `event_bridge_enabled`, `point_in_time_recovery`, `deletion_protection` |

## Monitoring and Alerting

### Cluster and Infrastructure Monitoring

| Cloud | Service | Component |
|-------|---------|-----------|
| AWS | CloudWatch alarms (CPU, memory, node count, API errors), SNS topics (critical/warning/info) | `observability` |
| GCP | Cloud Monitoring alert policies, notification channels | `observability` |
| Azure | Azure Monitor metric alerts, Action Groups | `observability` |

The `observability` component on each cloud creates alarms/alerts for configurable thresholds. Subscribe team emails via `alert_email_endpoints` or a Slack webhook via `slack_webhook_url`.

### Budget Alerts

| Cloud | Service | Component |
|-------|---------|-----------|
| AWS | AWS Budgets + Cost Anomaly Detection | `cost` |
| GCP | Cloud Billing budgets + programmatic alerts | `cost` |
| Azure | Azure Cost Management budgets + anomaly alerts | `cost` |

The `cost` component creates budget alerts at configurable thresholds (e.g., 50%, 80%, 100% of `monthly_budget_limit`). Notifications go to `budget_alert_emails`.

### Quota Alerts (service-quotas)

The `service-quotas` component monitors cloud service limits and creates alarms when usage exceeds `quota_threshold_percent` (default 80%).

| Cloud | Monitored Quotas |
|-------|-----------------|
| AWS | VPCs per region, EIPs, NAT gateways, EKS clusters, Lambda concurrent executions |
| GCP | VPC networks, external IPs, GKE clusters, CPU/GPU quotas per region |
| Azure | VNets per subscription, public IPs, AKS clusters, vCPU quotas per region |

### Drift Detection (drift.yml)

Production infrastructure is checked for drift every weekday morning. Currently AWS-only; GCP and Azure drift detection is planned. Drift issues appear in GitHub with the `drift` label. See the CI/CD section above for details.

## Secrets Management

The `secrets` component manages encryption and secrets infrastructure per cloud:

| Cloud | Encryption | Secrets Store | Pod Access |
|-------|-----------|---------------|------------|
| AWS | KMS (customer-managed, auto-rotation) | Secrets Manager | IRSA for External Secrets Operator |
| GCP | Cloud KMS (automatic rotation) | Secret Manager | Workload Identity for External Secrets Operator |
| Azure | Key Vault (software or HSM keys) | Key Vault Secrets | Workload Identity for External Secrets Operator |

The flow: secrets are stored in the cloud secrets store, External Secrets Operator (running in the Kubernetes cluster, authenticated via workload identity) syncs them, and Kubernetes Secrets are created for pod consumption.

## Backup and Recovery

The `backup` component manages backup infrastructure per cloud:

| Cloud | Service | Key Features |
|-------|---------|-------------|
| AWS | AWS Backup | Configurable plans, vault lock for production, KMS encryption, cross-region copy |
| GCP | Cloud Storage versioning + scheduled snapshots | Lifecycle policies, retention configuration |
| Azure | Azure Backup + Recovery Services Vault | Configurable policies, soft delete, geo-redundant storage |

Backup plans are configurable via the `backup_plans` map (schedule, retention, cold storage transition). Email notifications go to `notification_emails`.

### Restore Procedure

1. Open the backup console for the relevant cloud (AWS Backup / GCP Console / Azure Recovery Services)
2. Navigate to the vault and find the recovery point
3. Select "Restore" and configure the target resource settings
4. Monitor the restore job in the console

For state file recovery, see [RB-004: Failed Apply](runbooks.md#rb-004-failed-apply--partial-state) in the runbooks.
