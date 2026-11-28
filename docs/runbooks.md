# Runbooks

Step-by-step procedures for common operational scenarios.

## RB-001: Drift Detected

**Trigger:** GitHub issue created by `drift.yml` with the `drift` label.

### Triage

1. Open the GitHub issue and read the plan output
2. Identify what changed and classify the cause:
   - **Manual console change** — someone modified a resource outside of OpenTofu
   - **AWS-initiated change** — AWS updated a default, deprecated a setting, or auto-scaled a resource
   - **Upstream dependency** — another system modified a shared resource
   - **Provider update** — a new provider version reads attributes differently

### Remediate

**If the drift should be reverted** (unauthorized change):

```bash
task apply ACCOUNT=workload-production ENVIRONMENT=production COMPONENT=<component>
```

This brings the resource back to the declared state.

**If the drift should be adopted** (legitimate change):

1. Update the component's `variables.tf` defaults or the environment's `terragrunt.hcl` inputs to match the current state
2. Plan to confirm zero diff: `task plan ACCOUNT=workload-production ENVIRONMENT=production COMPONENT=<component>`
3. Open a PR with the changes

### Close Out

1. Close the GitHub issue with a comment explaining the cause and resolution
2. If the drift was unauthorized, investigate how it happened and whether access controls need tightening

---

## RB-002: State Lock Stuck

**Symptom:** `Error acquiring the state lock` when running plan or apply.

### Identify the Lock Holder

OpenTofu uses native S3 conditional writes for locking (`use_lockfile = true`). The lock is an object beside the state, at the state's key with `.tflock` appended. `live/root.hcl` keys a leaf's state by its environment and then its path under `live/`, so the leaf at `live/aws/<account>/<region>/<env>/<component>/` keeps its state at `<env>/aws/<account>/<region>/<env>/<component>/terraform.tfstate`. From the leaf's directory, `terragrunt render --format json | jq -r .remote_state.config.key` prints the key.

1. Check if another `plan` or `apply` is still running (CI workflow, colleague, etc.)
2. Check the S3 bucket for a `.tflock` file:
   ```bash
   aws s3 ls s3://<account_id>-<region>-tfstate/<env>/aws/<account>/<region>/<env>/<component>/
   ```

### Force Unlock (if safe)

Only force-unlock if you are certain no other operation is in progress.

```bash
cd live/aws/<account>/<region>/<env>/<component>
terragrunt force-unlock <lock-id>
```

If `force-unlock` cannot release it, delete the lock object directly:

```bash
aws s3 rm s3://<account_id>-<region>-tfstate/<env>/aws/<account>/<region>/<env>/<component>/terraform.tfstate.tflock
```

### Prevention

- Avoid running `apply` from local machines when CI is active
- Use the `deploy.yml` workflow for all applies to serialize operations

---

## RB-003: Break-Glass Access

**When:** production incident requiring elevated AWS access beyond normal SSO permissions.

### Assume the Break-Glass Role

1. Get the break-glass role ARN from the `break-glass` component outputs or from a platform engineer
2. Assume the role:
   ```bash
   aws sts assume-role \
     --role-arn arn:aws:iam::<account_id>:role/<break-glass-role> \
     --role-session-name "incident-<your-name>-$(date +%Y%m%d)"
   ```
3. Export the returned credentials:
   ```bash
   export AWS_ACCESS_KEY_ID=<...>
   export AWS_SECRET_ACCESS_KEY=<...>
   export AWS_SESSION_TOKEN=<...>
   ```

### During the Incident

- The role has a maximum session duration (default 1 hour)
- SNS notifications fire when the role is assumed — the security team is automatically alerted
- Document every action you take

### Post-Incident

1. Let the session expire (do not extend unless necessary)
2. Unset the exported credentials
3. Write an incident report documenting:
   - Why break-glass was needed
   - What actions were taken
   - Whether any infrastructure changes need to be codified
4. Review with the security team whether the incident reveals gaps in normal access permissions

---

## RB-004: Failed Apply / Partial State

**Symptom:** `apply` failed midway, leaving some resources created and others not.

### Do NOT Destroy

A partial apply means some resources exist in state and in AWS. Running `destroy` may fail or leave orphaned resources. Instead:

### Assess the Damage

1. Run `plan` to see what OpenTofu thinks the current state is:
   ```bash
   task plan ACCOUNT=workload-<env> ENVIRONMENT=<env> COMPONENT=<component>
   ```
2. Review the plan output — it will show what still needs to be created/updated

### Fix and Re-Apply

1. Fix the root cause of the failure (permissions, quota, invalid input, etc.)
2. Re-run apply:
   ```bash
   task apply ACCOUNT=workload-<env> ENVIRONMENT=<env> COMPONENT=<component>
   ```
3. OpenTofu is idempotent — it will skip already-created resources and create/update the remaining ones

### State Corruption Recovery

If the state file itself is corrupted:

1. S3 versioning is enabled — list previous versions. The key is the leaf's environment and then its path under `live/`, as [RB-002](#rb-002-state-lock-stuck) explains:
   ```bash
   aws s3api list-object-versions \
     --bucket <account_id>-<region>-tfstate \
     --prefix <env>/aws/<account>/<region>/<env>/<component>/terraform.tfstate
   ```
2. Download a known-good version:
   ```bash
   aws s3api get-object \
     --bucket <account_id>-<region>-tfstate \
     --key <env>/aws/<account>/<region>/<env>/<component>/terraform.tfstate \
     --version-id <version-id> \
     terraform.tfstate.backup
   ```
3. Upload it as the current version:
   ```bash
   aws s3 cp terraform.tfstate.backup \
     s3://<account_id>-<region>-tfstate/<env>/aws/<account>/<region>/<env>/<component>/terraform.tfstate
   ```
4. Plan to verify the restored state matches reality

---

## RB-005: Adding a New AWS Account

### Prerequisites

- AWS Organizations access (management account)
- The new account must be a member of the organization

### Steps

1. **Create the account** in AWS Organizations (or import an existing one)

2. **Update org-identity** — add the account to `account_assignments` so SSO users can access it:
   ```bash
   task plan ACCOUNT=management ENVIRONMENT=org COMPONENT=org-identity
   task apply ACCOUNT=management ENVIRONMENT=org COMPONENT=org-identity
   ```

3. **Update org-scp** — attach appropriate SCPs to the account's OU:
   ```bash
   task plan ACCOUNT=management ENVIRONMENT=org COMPONENT=org-scp
   task apply ACCOUNT=management ENVIRONMENT=org COMPONENT=org-scp
   ```

4. **Update org-security** — add the account to `member_accounts` for GuardDuty/Security Hub:
   ```bash
   task plan ACCOUNT=management ENVIRONMENT=org COMPONENT=org-security
   task apply ACCOUNT=management ENVIRONMENT=org COMPONENT=org-security
   ```

5. **Create the state bucket** in the new account:
   ```bash
   ./scripts/init-backend-aws.sh <new_account_id> <region>
   ```

6. **Create the environment directory** by copying an existing one under
   `live/aws/<account>/<region>/<env>/`:
   ```bash
   cp -r live/aws/workload-development/us-east-1/development/ live/aws/<new-account>/<region>/<new-env>/
   ```

7. **Set the account metadata across the three scoped `.hcl` files** — each level owns a different value:
   - `live/aws/<new-account>/account.hcl` — the new account ID and alias (`account_id`, `account_alias`)
   - `live/aws/<new-account>/<region>/region.hcl` — the region
   - `live/aws/<new-account>/<region>/<new-env>/env.hcl` — the environment name and its metadata

8. **Deploy in dependency order:**
   ```bash
   task apply ACCOUNT=<new-account> ENVIRONMENT=<new-env>
   ```

---

## RB-006: EKS Cluster Upgrade

### Preparation

1. Check the [EKS release notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) for the target version
2. Verify Karpenter, Cilium, and ArgoCD compatibility with the target Kubernetes version
3. Review the cluster-addons components for any version-pinned resources

### Upgrade Sequence

Always roll through environments: **development → staging → production**.

For each environment:

1. **Update the cluster version** in `live/aws/<account>/<region>/<env>/cluster/terragrunt.hcl`:
   ```hcl
   inputs = {
     cluster_version = "1.36"  # new version
   }
   ```

2. **Plan and review:**
   ```bash
   task plan ACCOUNT=workload-<env> ENVIRONMENT=<env> COMPONENT=cluster
   ```
   Verify the plan shows an in-place update of the EKS cluster version, not a replacement.

3. **Apply:**
   ```bash
   task apply ACCOUNT=workload-<env> ENVIRONMENT=<env> COMPONENT=cluster
   ```
   The EKS control plane upgrade takes 15–30 minutes.

4. **Verify cluster-bootstrap** — Cilium and ArgoCD should continue running. Plan to check:
   ```bash
   task plan ACCOUNT=workload-<env> ENVIRONMENT=<env> COMPONENT=cluster-bootstrap
   ```

5. **Verify cluster-addons:**
   ```bash
   task plan ACCOUNT=workload-<env> ENVIRONMENT=<env> COMPONENT=cluster-addons
   ```

6. **Validate workloads** — check that pods are running, services are healthy, and Karpenter is provisioning nodes with the new version

7. **Wait for stabilization** before proceeding to the next environment. Monitor the `observability` alarms for any issues.

### Rollback

EKS does not support in-place downgrades. If the upgrade fails:
- Karpenter nodes will continue running the old kubelet version until recycled
- Fix forward by addressing compatibility issues
- In extreme cases, restore from backup and rebuild the cluster at the old version

## RB-007: Tearing Down a Wedged EKS Fleet Vend

The `fleet-vend` / `fleet-hub` roles provision EKS spokes. Teardown — a
`tofu destroy` driven by deleting the Crossplane `Cluster` — can wedge for two
reasons: a vend role that is create-complete may be destroy-incomplete, and
Karpenter + EKS leave AWS residue that `tofu destroy` never owned. This is the
order and the known wedges from live spoke teardowns.

### Let the Composition Drive the Order

1. Delete the tenant ApplicationSets (eks-gitops) first.
2. Delete the `Cluster` CR. This cascades both Workspaces' `tofu destroy`. The
   composition's `Usage` (of: cluster-stack, by: cluster-bootstrap) blocks
   cluster-stack's teardown until cluster-bootstrap is gone, so the bootstrap
   destroys against a live API endpoint (its `tofu destroy` needs the spoke API)
   before the cluster itself is torn down.
3. Destroy the standalone substrate: the `fleet-vend` / `fleet-hub` roles, the
   tfstate bucket, the hub cluster.

### Create-Complete ≠ Destroy-Complete

The vend/hub roles minted everything on the create path but were missing a few
destroy-path permissions; each surfaced as a `tofu destroy` 403:

- `iam:ListInstanceProfilesForRole` / `iam:GetInstanceProfile` — the pre-delete
  role read.
- `iam:RemoveRoleFromInstanceProfile` + `iam:DeleteInstanceProfile` on
  Karpenter's **root-path** node instance profile `<cluster>_<hash>`. Karpenter
  (v1) creates it outside the `/eks-fleet/` path, so the path-scoped grant
  didn't cover it; the roles now also scope `instance-profile/<environment>-*`.

A fresh 403 on a destroy action is a missing permission on the vend/hub role —
fix the role and file it, don't reach for the manual workaround as the answer.

### The Residue tofu Doesn't Own

`tofu destroy` tears down what tofu created; Karpenter and EKS leave their own:

- **Karpenter EC2 instances** — terminate by tag `karpenter.sh/nodepool`; they
  block subnet/VPC deletion.
- **Karpenter SQS queue + EventBridge rules**, **EKS CloudWatch log groups** —
  `cloudgov orphans --profile <p>` finds these; reap them.
- **Versioned tfstate bucket** — `DeleteBucket` returns 409 `BucketNotEmpty`
  even when it looks empty. Purge every object *version* and delete marker
  first, then delete the bucket.

### When It's Truly Wedged (external-create-pending)

A Workspace stuck `external-create-pending` blocks both create and delete.
**Never cycle the `provider-opentofu` pod mid-apply** — it orphans the vend
(live AWS, empty S3 state). To clear:

1. Drop the Workspace finalizer so the managed resource deletes.
2. Delete the live AWS resources directly, in dependency order: EKS control
   plane → ENIs / security groups / subnets / VPC → IAM roles + instance
   profiles → CloudWatch log groups.
3. Refresh expired provider credentials through the `aws-creds` secret — not a
   pod restart.

### Close Out

Run `cloudgov orphans --profile <p>` in every touched account until clean.
Confirm zero EKS / NAT / VPC / EC2 / EBS / ELB / EIP before walking away. A
COMPLIANCE-locked S3 bucket (e.g. a Bedrock invocation-log bucket) stays
undeletable until its retention elapses — that's expected; leave it.

---

## RB-008: Retargeting an Account Tree to a Different Region

Moving `live/aws/<account>/<region>/` is mostly mechanical. Three things in it
are not, and none of them is caught by any gate in this repository.

### The directory name is cosmetic — change the local

`live/root.hcl` reads `local.region` out of `region.hcl`. It never looks at the
directory name. So `git mv`-ing the tree and stopping there produces a
repository that reads as retargeted in every diff, every path and every review,
and resolves the old region at plan time.

```bash
# after moving the tree, assert the values actually changed
for f in $(git ls-files 'live/aws/*/*/region.hcl'); do
  printf '%-44s %s\n' "$f" "$(grep -E '^\s*region\s*=' "$f")"
done
```

### Region-bearing values inside opaque strings are outside every gate's reach

A region can be embedded in any string a provider accepts — an ARN, a service
endpoint, an OIDC issuer URL, a bucket name. Nothing here parses inside those:
`check-account-local-deps.py` resolves paths, `tflint` and `checkov` read
resource shapes, and `terragrunt hcl validate --inputs` checks completeness.
None of them reads a region out of the middle of a string.

The one that bit this repo: `org-security` enrolled

    arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0

That names a *regional standard*, not a path. Left alone it would have applied
cleanly from a us-east-1 account and enrolled a standard in a region the org SCP
denies — and a successful apply would have looked like proof it was fine.

Do not try to build a gate for this. The set of strings that can carry a region
is not enumerable, and each pass would add whichever form escaped last time.
Grep the old region across the whole tree and read every hit instead:

```bash
git grep -n "<old-region>" -- 'live/**' 'scripts/**' '.github/**' 'docs/**' 'Taskfile.yaml'
```

Expect three categories, and decide each: *stale* (fix), *deliberate policy*
(e.g. an SCP allowlist naming more regions than the estate uses — narrowing it
is a security decision, not part of a move), and *mock values* (cosmetic, but
stale mocks mislead readers).

### Non-deployable trees break silently

`live/aws/reference-adopt/` is excluded from drift and e2e and applies nowhere,
so a stale path in it fails nothing, forever. It exists to be copied — a worked
example pointing at a directory that no longer exists is worse than no example.
Move it with the tree it references, in the same commit.

### Verify

```bash
# every leaf still resolves its includes, dependencies and inputs — no credentials
git ls-files 'live/**/terragrunt.hcl' | while read -r l; do
  ( cd "$(dirname "$l")" && terragrunt hcl validate --inputs ) || echo "FAILED: $l"
done
```

A leaf whose wiring broke in the move cannot pass that.

---

## RB-009: Cluster Alarms

**When:** a cluster's alert topic delivers a notification. `<cluster>-health-critical` entering ALARM is a page, `<cluster>-health-degraded` entering ALARM is a ticket, and either one returning to OK arrives on the info topic.

`<cluster>` is the EKS cluster's name, `<environment>-<cluster_name>` (for example `production-platform`), which is the `cluster` component's `cluster_name` output. Everything below is what `components/aws/observability/` builds for that cluster, in the cluster's account and region. Where a leaf sets `enable_cluster_alarms = false`, none of these alarms exist.

### Where Alerts Go

Only the two composite alarms notify. Each one ORs a set of child alarms that carry no action of their own, so a hard-down cluster pages once rather than once per firing alarm.

| Composite | Rolls up | ALARM goes to | OK goes to |
|-----------|----------|---------------|------------|
| `<cluster>-health-critical` | `api-server-5xx`, `failed-nodes`, and the `fast` and `quick` SLO burn pairs | critical topic | info topic |
| `<cluster>-health-degraded` | `node-cpu-high`, `node-memory-high`, and the `steady` and `slow` SLO burn pairs | warning topic | info topic |

Which topics those are depends on the leaf's `observability_mode`:

- **`create`**, the default: this account's `<cluster>-alerts-critical`, `<cluster>-alerts-warning` and `<cluster>-alerts-info`, encrypted with the `alias/<cluster>-alerts` key. Their ARNs are the `sns_topic_arns` output and the SSM parameters `/eks-agent-platform/<cluster>/observability/alerts_<severity>_topic_arn`. The critical and warning topics email each address in the leaf's `alert_email_endpoints`, the only subscription the component makes, so a leaf that lists none notifies nobody.
- **`adopt`**: the central topics `shared-observability` owns, passed in as `adopt_topic_arns`. Their subscriptions belong to that component.

### Escalation

A page is a message on the critical topic and a ticket is a message on the warning topic. Whoever subscribes to those topics receives them. This repository names no pager, rota or ticket queue: routing the critical and warning topics to one is the owner's to set up.

### Dashboard

`<cluster>-overview`, in CloudWatch in the cluster's account and region. The leaf's `dashboard_url` output links to it, and it exists where `enable_dashboard` is on. It reads top to bottom:

1. **SLO**, where the SLO alarms are on: the availability SLI against its objective over 30 days, the error budget remaining, and the 1h and 6h burn rates against the page (14.4x) and ticket (3x) lines.
2. **Errors and traffic**: the API server's error ratio, and its request rate with 5xx.
3. **Latency and load**: API server request duration (p50, p95, p99), and in-flight requests.
4. **Saturation**: node CPU, node memory, and nodes with running pods.
5. **Failure**: failed or not-ready nodes, and node network throughput.

### The Alarms

Every alarm reads the `ContainerInsights` namespace at the `ClusterName` dimension. The `amazon-cloudwatch-observability` EKS add-on publishes those metrics, with enhanced Container Insights on, through its agent: the `cloudwatch-agent` service account in the `amazon-cloudwatch` namespace.

| Alarm | Severity | Fires when | With no data |
|-------|----------|------------|--------------|
| `<cluster>-api-server-5xx` | critical | `apiserver_request_total_5xx`, summed over 5 minutes, exceeds `alarm_config.api_server_error_threshold` (default 5) in 3 consecutive periods | fires |
| `<cluster>-failed-nodes` | critical | `cluster_failed_node_count` exceeds 0 over one `alarm_config.node_not_ready_period` (default 300 seconds) | fires |
| `<cluster>-node-cpu-high` | warning | average `node_cpu_utilization` exceeds `alarm_config.cpu_utilization_threshold` (default 80%) in 3 consecutive 5-minute periods | does not fire |
| `<cluster>-node-memory-high` | warning | average `node_memory_utilization` exceeds `alarm_config.memory_utilization_threshold` (default 80%) in 3 consecutive 5-minute periods | does not fire |
| `<cluster>-slo-burn-<pair>` | critical for `fast` and `quick`, warning for `steady` and `slow` | the API server availability SLO (`slo_availability_objective`, default 0.999 over 30 days) spends its error budget at or above the pair's rate over both of its windows: `fast` 14.4x over 1h and 5m, `quick` 6x over 6h and 30m, `steady` 3x over 1d and 2h, `slow` 1x over 3d and 6h | does not fire |

Each SLO pair is a composite of two window alarms, `<cluster>-slo-burn-<pair>-long` and `<cluster>-slo-burn-<pair>-short`, and fires only while both do. The pairs exist where `enable_slo_alarms` is on as well as `enable_cluster_alarms`.

### First Checks

Start from the alarm's state reason in its CloudWatch history. A reason saying no datapoints were received means the metrics stopped, not the cluster: go to [When the Metrics Stop](#when-the-metrics-stop).

**`api-server-5xx`, and the SLO burn pairs**, which count the same 5xx series:

1. On the dashboard, the error ratio and request rate panels show whether errors rose or traffic fell.
2. `aws eks describe-cluster --name <cluster> --query cluster.health` lists the control-plane issues AWS reports.
3. An admission webhook whose service is down returns errors to every request it intercepts when its `failurePolicy` is `Fail`. List them with `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations` and check the services they name.

**`failed-nodes`:**

1. `kubectl get nodes` for nodes that are not `Ready`, then `kubectl describe node <node>` for the condition behind it: memory, disk or PID pressure, or a network that is not ready.
2. For a node Karpenter launched, `kubectl get nodeclaims` shows a claim that failed to launch or to register.

**`node-cpu-high` and `node-memory-high`:**

1. On the dashboard, whether one node or every node is saturated.
2. Container Insights' pod view of the cluster names the pods using the most CPU or memory. For memory, a pod restarting with `OOMKilled` in `kubectl describe pod` points at its limit or a leak.
3. Whether Karpenter can add capacity: each NodePool's `limits` cap what it launches (`kubectl get nodepools`).

### When the Metrics Stop

`api-server-5xx` and `failed-nodes` treat missing data as breaching, so a cluster that stops publishing pages as critical instead of reading healthy. The agent stops publishing when its nodes are too full to run it, when the add-on rolls back, or when its Pod Identity binding breaks:

1. `aws eks describe-addon --cluster-name <cluster> --addon-name amazon-cloudwatch-observability`: expect `ACTIVE` and no health issues.
2. `kubectl -n amazon-cloudwatch get pods`: the agent runs on every node.
3. `aws eks list-pod-identity-associations --cluster-name <cluster> --namespace amazon-cloudwatch`: the association for `cloudwatch-agent` exists.

Other components' alarms (service quotas, budgets, the break-glass delivery alarm) notify on their own topics and are outside this runbook.
