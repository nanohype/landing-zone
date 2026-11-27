# shared-backup

The owner side of **central backup**. A dedicated backup account runs this component to hold
the durable copy of every workload account's backups, so a recovery point survives the loss of
the account that produced it. It runs in us-east-1, the estate's only region, so the copy does
not survive the loss of the region.

## Where it sits

```
workload account                         backup account (us-east-1)
  backup                        ──copy──▶  shared-backup
  (local vault, fast restores)   job       (central vault, durable copy)
```

- **Local vault** (`components/aws/backup`, workload account) — fast in-account restores. Its
  plan rules gain a `copy_action` targeting this component's central vault.
- **Central vault** (this component, backup account) — the copy that survives an
  account-level event. Governance-locked; encrypted with a multi-region CMK.

This closes the seam where a backup living only in the account it protects is one account
event — a compromise, or a confident `DeleteBackupVault` — away from being gone alongside the
thing it protected. It is the data path region-model's backup-and-restore posture (RTO
hours, RPO ~24h) rests on, and the cross-region half of that posture waits on a second region.

## Cross-account copy authorization

A workload account copying into this vault is authorized on two surfaces, both scoped to the
organization by `aws:PrincipalOrgID` — a wildcard principal that admits exactly this org and
no external account:

1. **Vault access policy** — admits `backup:CopyIntoBackupVault`.
2. **Vault CMK policy** — admits the `Decrypt` / `GenerateDataKey*` / `CreateGrant` actions a
   copy job performs (CreateGrant carries the `GrantIsForAWSResource` guard).

The management account must also have cross-account backup enabled (an org-level AWS Backup
setting; see the `org-backup` component).

## Multi-region CMK

The vault CMK is multi-region because a cross-region restore cannot decrypt with the source
region's key — this is the first key that has to be (region-model R5). Replica keys are minted
per recovery region as a restore path demands one, not eagerly for every region. There is no
recovery region yet, so there is no replica.

## GOVERNANCE, not COMPLIANCE

The vault lock is GOVERNANCE mode: it keeps recovery points from deletion by any principal
without the explicit override permission, but a holder of that override can still remove it.
COMPLIANCE mode (set by `changeable_for_days`) becomes immutable after its grace period and
cannot be removed by anyone including the root account or AWS — the one-way door the estate
already paid tuition on with an S3 object lock. A vault flips to COMPLIANCE only for a named
regulation, recorded in the central-backup ledger at that time. Take the override permission
away from routine roles; do not take the exit away from everyone.

## Deploy

Standing up central backup is a multi-account act:

1. Provision the dedicated backup account and replace the `666666666666` placeholder in
   `live/aws/backup/account.hcl`.
2. Set the real `o-xxxxxxxxxx` organization id in `live/_envcommon/aws/shared-backup.hcl`.
3. Apply this component per environment (`live/aws/backup/us-east-1/<env>/shared-backup`).
4. Workload `backup` leaves already set `central_vault_arn` via
   `live/_envcommon/aws/backup.hcl` — composed from `live/aws/backup/account.hcl`,
   `live/aws/backup/us-east-1/region.hcl`, and the `<env>-central-backup-vault`
   naming convention. No per-leaf wiring step: once step 1 replaces the
   placeholder, the next apply of a workload `backup` leaf adds the copy action.
5. Enable cross-account backup at the org level (`org-backup`).

While `live/aws/backup/account.hcl` carries the `666666666666` placeholder, no ARN is
composed: `central_vault_arn` is empty, no plan rule carries a `copy_action`, and recovery
points stay in the workload account's own vault. Replacing the placeholder composes the ARN
for every workload `backup` leaf, so apply this component (step 3) before the next workload
apply.
