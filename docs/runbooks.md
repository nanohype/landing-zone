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
task apply ENVIRONMENT=production COMPONENT=<component>
```

This brings the resource back to the declared state.

**If the drift should be adopted** (legitimate change):

1. Update the component's `variables.tf` defaults or the environment's `terragrunt.hcl` inputs to match the current state
2. Plan to confirm zero diff: `task plan ENVIRONMENT=production COMPONENT=<component>`
3. Open a PR with the changes

### Close Out

1. Close the GitHub issue with a comment explaining the cause and resolution
2. If the drift was unauthorized, investigate how it happened and whether access controls need tightening

---

## RB-002: State Lock Stuck

**Symptom:** `Error acquiring the state lock` when running plan or apply.

### Identify the Lock Holder

OpenTofu uses native S3 conditional writes for locking (`use_lockfile = true`). The lock file is stored alongside the state file in S3.

1. Check if another `plan` or `apply` is still running (CI workflow, colleague, etc.)
2. Check the S3 bucket for a `.tflock` file:
   ```bash
   aws s3 ls s3://<account_id>-<region>-tfstate/<env>/<component>/
   ```

### Force Unlock (if safe)

Only force-unlock if you are certain no other operation is in progress.

```bash
cd live/<env>/<component>
terragrunt force-unlock <lock-id>
```

If using native S3 locking, you may need to delete the lock file directly:

```bash
aws s3 rm s3://<account_id>-<region>-tfstate/<env>/<component>/terraform.tfstate.tflock
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
   task plan ENVIRONMENT=<env> COMPONENT=<component>
   ```
2. Review the plan output — it will show what still needs to be created/updated

### Fix and Re-Apply

1. Fix the root cause of the failure (permissions, quota, invalid input, etc.)
2. Re-run apply:
   ```bash
   task apply ENVIRONMENT=<env> COMPONENT=<component>
   ```
3. OpenTofu is idempotent — it will skip already-created resources and create/update the remaining ones

### State Corruption Recovery

If the state file itself is corrupted:

1. S3 versioning is enabled — list previous versions:
   ```bash
   aws s3api list-object-versions \
     --bucket <account_id>-<region>-tfstate \
     --prefix <env>/<component>/terraform.tfstate
   ```
2. Download a known-good version:
   ```bash
   aws s3api get-object \
     --bucket <account_id>-<region>-tfstate \
     --key <env>/<component>/terraform.tfstate \
     --version-id <version-id> \
     terraform.tfstate.backup
   ```
3. Upload it as the current version:
   ```bash
   aws s3 cp terraform.tfstate.backup \
     s3://<account_id>-<region>-tfstate/<env>/<component>/terraform.tfstate
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
   task plan ENVIRONMENT=org COMPONENT=org-identity
   task apply ENVIRONMENT=org COMPONENT=org-identity
   ```

3. **Update org-scp** — attach appropriate SCPs to the account's OU:
   ```bash
   task plan ENVIRONMENT=org COMPONENT=org-scp
   task apply ENVIRONMENT=org COMPONENT=org-scp
   ```

4. **Update org-security** — add the account to `member_accounts` for GuardDuty/Security Hub:
   ```bash
   task plan ENVIRONMENT=org COMPONENT=org-security
   task apply ENVIRONMENT=org COMPONENT=org-security
   ```

5. **Create the state bucket** in the new account:
   ```bash
   ./scripts/init-backend.sh <new_account_id> <region>
   ```

6. **Create the environment directory:**
   ```bash
   cp -r live/dev/ live/<new-env>/
   ```

7. **Update `live/<new-env>/env.hcl`** with the new account ID, region, and environment name

8. **Deploy in dependency order:**
   ```bash
   task apply ENVIRONMENT=<new-env>
   ```

---

## RB-006: EKS Cluster Upgrade

### Preparation

1. Check the [EKS release notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) for the target version
2. Verify Karpenter, Cilium, and ArgoCD compatibility with the target Kubernetes version
3. Review the cluster-addons components for any version-pinned resources

### Upgrade Sequence

Always roll through environments: **dev → staging → production**.

For each environment:

1. **Update the cluster version** in `live/<env>/cluster/terragrunt.hcl`:
   ```hcl
   inputs = {
     cluster_version = "1.36"  # new version
   }
   ```

2. **Plan and review:**
   ```bash
   task plan ENVIRONMENT=<env> COMPONENT=cluster
   ```
   Verify the plan shows an in-place update of the EKS cluster version, not a replacement.

3. **Apply:**
   ```bash
   task apply ENVIRONMENT=<env> COMPONENT=cluster
   ```
   The EKS control plane upgrade takes 15–30 minutes.

4. **Verify cluster-bootstrap** — Cilium and ArgoCD should continue running. Plan to check:
   ```bash
   task plan ENVIRONMENT=<env> COMPONENT=cluster-bootstrap
   ```

5. **Verify cluster-addons:**
   ```bash
   task plan ENVIRONMENT=<env> COMPONENT=cluster-addons
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
