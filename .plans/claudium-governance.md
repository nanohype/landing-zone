# Absorb claudium Identity-Center governance

Master plan: `/Users/bs/.claude/plans/prancy-rolling-dijkstra.md` Phase 1b.

Re-implements the genuinely-additive governance from `stxkxs/claudium`'s CDK
Identity-Center package as OpenTofu, using the existing `org-scp` / `org-identity`
input maps. No component code changed — only the `live/.../org/*/terragrunt.hcl`
input maps. CDK itself is not ported (org default substrate is OpenTofu, not CDK).

## org-scp — 3 SCPs added

`live/aws/management/us-west-2/org/org-scp/terragrunt.hcl` → `inputs.policies`:

- **`DenyBedrockEgressOutsideRegion`** — the reframed egress guardrail. claudium's
  `DenyClaudeEgressOutsideGateway` keyed on a `claudium:gateway` tag for a gateway
  this org retired (abca99b). There is no Bedrock VPC endpoint to key on, and SCPs
  gate API actions, not the cloudflared tunnel's network egress — so the honest
  guardrail is region-pinning `bedrock:Invoke*`/`Converse*`, mirroring the existing
  `RegionRestriction` allowlist. Safe against every current Bedrock caller
  (agentgateway + IRSA callers all invoke in us-west-2 / us-east-1).
- **`EnforceMandatoryTags`** — ported; required tags reconciled to nanohype's keys
  (`Workspace` → `PlatformId`; `DataClassification` kept).
- **`DenyKmsDecryptWithoutPlatformContext`** — renamed defense-in-depth atop the
  operator's per-key `EncryptionContextEquals {PlatformId}` grants. Bites
  `ManagedBy=eks-agent-platform` data keys; the opentofu-managed secrets/logs keys
  use a different context key and stay out of scope.

All ship with `target_ids = []` (create, don't attach) per repo convention.

## org-identity — 6 personas + 3 groups added

`live/aws/management/us-west-2/org/org-identity/terragrunt.hcl`:

- Personas: `PlatformAdmin`, `TenantAdmin`, `TenantDeveloper`, `Auditor`, `FinOps`,
  `AppReadOnly`. Static human-SSO sets (distinct from per-tenant pod IRSA, which the
  operator mints). claudium's per-Workspace parameterization dropped; tenant scoping
  expressed via `aws:ResourceTag/PlatformId` conditions. Renamed to nanohype
  vocabulary + to avoid colliding with the existing `Developer` / `ReadOnly` sets.
- Groups: `tenant-admins`, `auditors`, `finops`. `account_assignments` left `[]`.

## Rollout / flags

- **`EnforceMandatoryTags` blast radius**: landing-zone's own applies may create
  resources without `PlatformId`. Attach to a **dev OU first**, watch for
  `AccessDenied`, then promote. Do not attach org-root on first apply.
- **KMS SCP tag signal**: verify the data CMK carries `ManagedBy=eks-agent-platform`
  before attaching; if it's `ManagedBy=opentofu`, switch to a dedicated data-key tag
  so the SCP doesn't catch the secrets/logs key.
- **`Auditor`** uses managed `SecurityAudit` + a targeted secrets deny rather than
  claudium's fragile `NotActions` enforcement.

## Verify

```sh
terragrunt hcl fmt --file live/aws/management/us-west-2/org/org-scp/terragrunt.hcl
terragrunt hcl fmt --file live/aws/management/us-west-2/org/org-identity/terragrunt.hcl
terragrunt hcl validate --working-dir live/aws/management/us-west-2/org/org-scp        # exit 0
terragrunt hcl validate --working-dir live/aws/management/us-west-2/org/org-identity    # exit 0
```

`hcl validate --inputs` confirms all inputs are recognized; the `environment`/`region`
"missing" errors are pre-existing baseline noise (same on unmodified org components —
those values resolve from the env.hcl/region.hcl hierarchy at full-plan time). A real
`tofu plan` runs in CI with OIDC into the management account; expect only additions
(3 policies, 6 permission sets + attachments, 3 groups, new SSM params), no replacements.
