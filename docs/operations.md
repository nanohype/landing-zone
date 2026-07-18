# Operations

Day-to-day procedures for operating the landing-zone infrastructure.

## Planning and Applying

### Single Component

```bash
task plan ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=network
task apply ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=network
```

### All Components in an Environment

```bash
task plan ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development
task apply ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development
```

Terragrunt resolves the dependency graph and runs components in the correct order.

### Organization Components

```bash
task plan ACCOUNT=management REGION=us-west-2 ENVIRONMENT=org COMPONENT=org-identity
task apply ACCOUNT=management REGION=us-west-2 ENVIRONMENT=org COMPONENT=org-identity
```

## Deployment Order

For a from-scratch deployment, components must be applied in dependency order: `network -> cluster -> workloads + standalone`.

### Organization (run first, once)

```
1. org-scp
2. org-identity
3. org-security
4. org-compliance
5. org-cost
6. org-networking
```

Order within the org layer is flexible -- these components have no inter-dependencies.

### Per Environment (development -> staging -> production)

```
1. network                    (create mode by default; adopt mode participates in a shared VPC)
2. cluster
3. cluster-bootstrap          (depends on cluster)
4. cluster-addons             (depends on cluster)
5. secrets                    (depends on cluster)
6. observability              (depends on cluster)
7. agent-iam                  (depends on cluster; mints the operator role + tenant boundary)
8. druid                      (depends on network + cluster)
9. pipeline                   (depends on network + cluster)
10. llm                       (depends on network + cluster)
11. gateway                   (depends on cluster)
12. rag                       (depends on cluster)
13. mlops                     (depends on cluster)
14. governance                (depends on cluster)
15. competitive-intelligence-platform  (depends on network + cluster + agent-iam)
16. digest-pipeline-platform           (depends on network + cluster + agent-iam)
17. incident-response-platform         (depends on cluster + agent-iam)
18. slack-knowledge-bot-platform       (depends on network + cluster + agent-iam)
19. cost                      (standalone)
20. dns                       (standalone)
21. backup                    (standalone)
22. break-glass               (standalone)
23. service-quotas            (standalone)
24. github-oidc               (standalone)
```

Steps 3-14 can run in parallel within their dependency tier; the four `*-platform` tenants
(15-18) need `agent-iam` first (and their `Platform` CR `Ready` before the Pod Identity
association applies — see [First-time AWS Deploy](first-deploy-aws.md)). Steps 19-24 can run at
any time.

The cross-account **network-owner** components (`shared-network`, `egress-network`) and the
**hub** control plane (`managed-monitoring`, `fleet-*`, `portal-*`) deploy from their own
`live/aws/network/` and `live/aws/fleet/` trees, not the per-environment workload accounts.

Using `task apply ACCOUNT=<account> REGION=<region> ENVIRONMENT=<env>` (without `COMPONENT`) runs `terragrunt run --all -- apply`, which handles ordering automatically.

## CI/CD Workflows

### ci.yml -- Pull Request Validation

**Triggers:** PRs to `main`, pushes to `main`.

| Job | Details |
|-----|---------|
| **placeholders** | Runs `scripts/no-placeholders.sh`. Hard gate -- fails if an unfilled `PLACEHOLDER`/`FILL_ME`/`<YOUR_*>`-style sentinel appears in applied deploy config. |
| **fmt** | Runs `tofu fmt -check -recursive` on `components/`, `modules/`, and `fleet/`, plus `terragrunt hcl format --check` on the Terragrunt HCL layer. Fails if any file is unformatted. |
| **validate** | Matrix auto-discovered from the tree via `git ls-files` -- one entry per component, fleet vend root, and shared module. Runs `tofu init -backend=false` then `tofu validate`. Catches syntax errors and missing variable definitions. |
| **test** | Auto-discovers every `tests/*.tftest.hcl` suite under `modules/` and `components/` and runs `tofu test` at plan-time against mocked providers (no AWS access). Hard gate on the security contracts (Pod-Identity-only trust, boundary-gated tenant-role writes). |
| **tflint** | Runs TFLint recursively with the AWS plugin (`.tflint-aws.hcl`) at `--minimum-failure-severity=notice`. Enforces naming conventions, documented variables/outputs, unused-declaration, and version-constraint rules as hard failures. |
| **checkov** | Security scan on `components/aws/`, `fleet/aws/`, and `modules/aws/`. Hard gate -- any finding not covered by the documented skip list in `.checkov.yaml` fails the build. |
| **evaluate** | Credential-less `terragrunt render` on every live leaf. Catches include/function/dependency-wiring breakage that per-component `tofu validate` cannot see. |
| **mock-outputs** | Runs `scripts/check-mock-outputs.py` -- cross-checks every dependency `mock_outputs` key against the target component's real `outputs.tf`, so a renamed output fails here instead of resolving to a stale mock. |
| **plan** | PRs only. Matrix auto-discovered from `live/`. Runs `terragrunt plan` to show what would change (credential-gated -- skips green when `AWS_ROLE_ARN` is unset). |

### deploy.yml -- Manual Deploy

**Trigger:** Workflow dispatch (manual).

**Inputs:**
- `account` -- target account alias
- `region` -- target region
- `environment` -- development, staging, or production (the `environment` input is a fixed choice)
- `component` -- specific component name or "all"
- `action` -- plan or apply

Uses GitHub environment protection rules -- production requires approval. When `component=all`, runs `terragrunt run --all -- <action>`. Otherwise targets the specific component directory.

The `environment` choice covers only the three workload environments. The management-account `org` components (the [Organization Components](#organization-components) above) are **local-CLI-only** — deploy them with `task apply ACCOUNT=management ENVIRONMENT=org COMPONENT=<component>` under your own admin/SSO credentials. `org` is intentionally not a workflow choice because the management account is applied rarely and by hand.

### destroy.yml -- Manual Destroy

**Trigger:** Workflow dispatch (manual).

**Inputs:**
- `environment` -- development or staging only (production excluded)
- `component` -- specific component name or "all"
- `confirm` -- must exactly match the environment name

The confirmation guard (`confirm == environment`) prevents accidental destroys. Runs `terragrunt destroy` or `terragrunt run --all -- destroy`.

### drift.yml -- Drift Detection

**Trigger:** Cron schedule, 6 AM UTC Monday-Friday. Also supports manual dispatch.

**Scope:** every `production` and `staging` live leaf, matrix auto-discovered from the tree with `git ls-files` (mirroring `ci.yml`) -- a new production/staging component starts being watched with no workflow edit. Development is ephemeral and the `org`/`hub` control planes are covered by their own bring-up, so both are excluded.

**Behavior:** Runs `terragrunt plan -detailed-exitcode` for each discovered leaf. Exit code 2 means changes detected (drift). When drift is found, creates or updates a GitHub issue labelled `drift` with the plan output. Credential-gated: the job skips green until `AWS_ROLE_ARN` is set.

**Response:** See [RB-001: Drift Detected](runbooks.md#rb-001-drift-detected) in the runbooks.

## Tenant Management

Seven components are multi-tenant (`druid`, `pipeline`, `gateway`, `llm`, `mlops`, `rag`, `governance`).

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
4. Plan to verify: `task plan ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=<component>`
5. Apply: `task apply ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=<component>`

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
| **pipeline** | `batch_enabled`, `msk_enabled`, `batch_max_vcpus`, `deletion_protection` |
| **gateway** | `waf_enabled`, `cognito_enabled`, `waf_rate_limit`, `throttle_rate/burst/quota` |
| **llm** | `efs_performance_mode`, `sqs_visibility_timeout`, `dynamodb_pitr`, `deletion_protection` |
| **mlops** | `ecr_enabled`, `point_in_time_recovery`, `run_ttl_days`, `deletion_protection` |
| **rag** | `opensearch_standby_replicas`, `opensearch_dimensions`, `document_versioned`, `deletion_protection` |
| **governance** | `object_lock_enabled`, `event_bridge_enabled`, `point_in_time_recovery`, `deletion_protection` |

## Monitoring and Alerting

### Cluster and Infrastructure Monitoring

The `observability` component creates CloudWatch alarms (CPU, memory, node count, API errors) with configurable thresholds and SNS topics (critical/warning/info). Subscribe team emails via `alert_email_endpoints` or a Slack webhook via `slack_webhook_url`.

### Budget Alerts

The `cost` component creates AWS Budgets alerts at configurable thresholds (e.g., 50%, 80%, 100% of `monthly_budget_limit`) plus Cost Anomaly Detection. Notifications go to `budget_alert_emails`.

### Quota Alerts (service-quotas)

The `service-quotas` component monitors service limits -- VPCs per region, EIPs, NAT gateways, EKS clusters, Lambda concurrent executions -- and creates alarms when usage exceeds `quota_threshold_percent` (default 80%).

### Drift Detection (drift.yml)

Production and staging infrastructure is checked for drift every weekday morning. Drift issues appear in GitHub with the `drift` label. See the CI/CD section above for details.

## Secrets Management

The `secrets` component manages encryption and secrets infrastructure: customer-managed KMS keys with auto-rotation, Secrets Manager as the secrets store, and an IRSA role for External Secrets Operator.

The flow: secrets are stored in Secrets Manager, External Secrets Operator (running in the cluster, authenticated via IRSA) syncs them, and Kubernetes Secrets are created for pod consumption.

## Backup and Recovery

The `backup` component manages AWS Backup: configurable plans, vault lock for production, KMS encryption, and cross-region copy.

Backup plans are configurable via the `backup_plans` map (schedule, retention, cold storage transition). Email notifications go to `notification_emails`.

### Restore Procedure

1. Open the AWS Backup console
2. Navigate to the vault and find the recovery point
3. Select "Restore" and configure the target resource settings
4. Monitor the restore job in the console

For state file recovery, see [RB-004: Failed Apply](runbooks.md#rb-004-failed-apply--partial-state) in the runbooks.
