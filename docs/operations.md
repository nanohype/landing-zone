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
7. agent-iam                  (depends on cluster + secrets; mints the operator role + tenant boundary)
8. druid                      (depends on network + cluster)
9. pipeline                   (depends on network + cluster)
10. governance                (depends on cluster)
11. private-dns               (depends on cluster)
12. managed-monitoring        (depends on cluster; the environment's own AMP/AMG workspaces)
13. tenant-substrate          (depends on network + cluster; provisions each tenant's declared datastores)
14. cost                      (standalone)
15. dns                       (standalone)
16. backup                    (standalone)
17. break-glass               (standalone)
18. service-quotas            (standalone)
19. model-import              (standalone; environment+account+region-scoped Bedrock import substrate)
```

Steps 3-12 can run in parallel within their dependency tier; `tenant-substrate` (13) provisions a
tenant's declared datastores, its `var.tenants` map rendered from the Platform CRs — the operator
owns the tenant IAM + Pod Identity (see [First-time AWS Deploy](first-deploy-aws.md)). Steps 14-19
can run at any time.

Every component in that list has a live root in **all three** workload environments, so the
sequence is the same everywhere and `run --all` resolves it.

`github-oidc` is deliberately not in the sequence: it is applied **once per account**, not once per
environment, so it carries a single `development` live root and adding siblings would mint the same
account-level OIDC provider three times.

The cross-account **network-owner** components (`shared-network`, `egress-network`) and the
**hub** control plane (`fleet-*`, `portal-*`) deploy from their own `live/aws/network/` and
`live/aws/fleet/` trees, not the per-environment workload accounts.

`managed-monitoring` deploys from both: each workload environment runs its own for that
environment's AMP/AMG workspaces, and the hub runs one of its own. It is in the per-environment
sequence above for that reason.

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
| **smoke-outputs** | Runs `scripts/check-smoke-outputs.py` -- cross-checks every output key a `components/**/smoke-test.sh` reads via `jq` against that component's real `outputs.tf`. `jq` yields the string "null" for a key that does not exist, so a stale read makes the smoke test assert against nothing; this fails the build instead. |
| **account-local-deps** | Runs `scripts/check-account-local-deps.sh` -- a leaf under `live/aws/workload-*/` may not depend on a unit outside its own account directory. A terragrunt `dependency` resolves at config-parse time, so a cross-account one fails `init`, not just `apply`, and no `TF_VAR` bypasses it. CI cannot otherwise see this: `evaluate` resolves against mocks by design and `plan` green-skips without credentials. |
| **architecture-components** | Runs `scripts/check-architecture-components.sh` -- the architecture doc's component inventory must be the components that exist, both directions. A documented component that is gone sends a reader to a missing directory; a component no table names is quieter and worse, because the doc reads as complete. |
| **teardown-gates** | Runs `scripts/check-teardown-gates.py` -- in a component declaring `force_destroy_buckets`, every teardown-gate attribute must resolve permissively when the lever is set, and every protectable resource must carry one. A module without the lever declares why in the script's EXEMPT table. No tflint or checkov rule covers `force_destroy` or `deletion_protection`, and a `tofu test` assert cannot reach a grandchild module's attributes. |
| **tenant-schema-readers** | Runs `scripts/check-tenant-schema-readers.py` -- every field a `tenants` object type declares must be read by a resource in that component. A field with no reader is a control an operator can set, sees accepted, and believes is in force. |
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

Four components are multi-tenant: `druid`, `pipeline`, `governance` and `tenant-substrate`.

`tenant-substrate` is the generic one — its `tenants` map is rendered from the Platform CRs
by the factory, so a tenant arrives there by declaring `spec.datastores`, not by editing a
leaf. The other three carry hand-authored sizing maps in their live leaves.

### Adding a Tenant

1. Identify the component(s) the tenant needs (e.g. `druid`, `pipeline`)
2. Edit the environment's `terragrunt.hcl` for each component
3. Add an entry to the `tenants` map:
   ```hcl
   tenants = {
     new-tenant = {
       # see variables.tf for the full schema and defaults
       msk_enabled = true
     }
   }
   ```
4. Plan to verify: `task plan ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=<component>`
5. Apply: `task apply ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=<component>`

### Removing a Tenant

Removing one tenant while the component stays up is a per-tenant act:

1. Clear that tenant's protection and apply. Which field depends on the component:
   `druid` and `governance` take `deletion_protection = false`; `tenant-substrate` takes
   `relational.deletion_protection = false` per relational datastore; `pipeline` has no
   such gate and needs nothing
2. Remove the tenant entry from the `tenants` map
3. Plan and verify the destroy actions
4. Apply

### Tearing Down a Whole Component

Different act, different lever. `force_destroy_buckets` is the operator's declaration that
this substrate is disposable, and it opens **every** teardown gate the component has at
once — bucket `force_destroy`, Aurora's final snapshot and deletion protection, DynamoDB
deletion protection, and Secrets Manager's recovery window. Development permits all of it
unconditionally.

It is deliberately two acts, not one flag: none of those attributes take effect until an
apply lands them in state, so permitting a teardown and performing one are separate
commands. There is no single invocation that reaches a populated production bucket.

Do not gate a subset. AWS spreads these protections across resources the dependency graph
does not join, so the destroy walks them concurrently — a component whose buckets open
while its database stays protected empties the data, fails on the database, and halts the
reverse sweep above cluster and network, leaving EKS, the VPC and the NAT gateways
billing. `scripts/check-teardown-gates.py` holds that property in CI.

### Tenant Configuration Reference

Each multi-tenant component has different tenant fields. Check the `variables.tf` in the
component for the full schema:

| Component | Key Tenant Fields |
|-----------|------------------|
| **druid** | `rds_min_acu`, `rds_max_acu`, `rds_backup_days`, `msk_enabled`, `deletion_protection` |
| **pipeline** | `batch_enabled`, `msk_enabled`, `batch_max_vcpus`, `batch_type` |
| **governance** | `event_bridge_enabled`, `point_in_time_recovery`, `deletion_protection` |
| **tenant-substrate** | per-datastore: `deletion_policy`, plus the `relational` / `keyValue` / `objectStore` / `queue` / `cache` / `stream` blocks the Platform CR declares |

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

The `secrets` component manages encryption and storage: customer-managed KMS keys with auto-rotation, and Secrets Manager as the secrets store. The External Secrets Operator role sits in `cluster-addons` with every other addon identity, because a ServiceAccount holds exactly one EKS Pod Identity association.

The flow: secrets are stored in Secrets Manager, External Secrets Operator (running in the cluster, authenticated by an EKS Pod Identity role bound to its ServiceAccount) syncs them, and Kubernetes Secrets are created for pod consumption.

## Backup and Recovery

The `backup` component manages AWS Backup: configurable plans, vault lock for production, KMS encryption, and cross-region copy.

Backup plans are configurable via the `backup_plans` map (schedule, retention, cold storage transition). Email notifications go to `notification_emails`.

### Restore Procedure

1. Open the AWS Backup console
2. Navigate to the vault and find the recovery point
3. Select "Restore" and configure the target resource settings
4. Monitor the restore job in the console

For state file recovery, see [RB-004: Failed Apply](runbooks.md#rb-004-failed-apply--partial-state) in the runbooks.
