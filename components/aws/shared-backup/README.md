# shared-backup

The owner side of **central backup**. A dedicated backup account runs this component in the
DR region to hold the durable copy of every workload account's backups, so a recovery point
survives the loss of the account that produced it.

## Where it sits

```
workload account                         backup account (DR region)
  backup                        ──copy──▶  shared-backup
  (local vault, fast restores)   job       (central vault, durable copy)
```

- **Local vault** (`components/aws/backup`, workload account) — fast in-account restores. Its
  plan rules gain a `copy_action` targeting this component's central vault.
- **Central vault** (this component, backup account, DR region) — the copy that survives an
  account-level event *and* a region loss. Governance-locked; encrypted with a multi-region
  CMK.

This closes the seam where a backup living only in the account it protects is one account
event — a compromise, or a confident `DeleteBackupVault` — away from being gone alongside the
thing it protected. It is the DR data path region-model's backup-and-restore posture (RTO
hours, RPO ~24h) rests on.

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
per recovery region as a restore path demands one, not eagerly for every region.

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
4. Wire the resulting `central_vault_arn` into each workload account's `backup` leaf
   (`central_vault_arn = ...`) so its plan rules begin copying.
5. Enable cross-account backup at the org level (`org-backup`).

Until the backup account exists, workload `backup` components run with `central_vault_arn`
unset — a local vault and no copy action, the shape before central backup is stood up.
