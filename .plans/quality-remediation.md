# Quality remediation — landing-zone

Tactical plan for this repo's targets in the org quality-remediation campaign.
Master plan: `~/.claude/plans/quality-remediation.md` (read its loop protocol and
decision ledger first — U3/U4 and the default decisions are settled).

Audit baseline: `6ae06a9`, 2026-07-16. Grades: architecture B, patterns B+, systems C+,
testing B-, security B, code_quality D (cap), documentation B-, consistency D (cap),
ai_systems B-. The systems C+ reflects two executable-verified broken paths that merged
green because `fleet/` and terragrunt evaluation sit outside every enforced CI gate.

Repo gotcha that binds every target: `.terraform.lock.hcl` files are tracked
intentionally — never bulk-delete them.

## Status

| # | target | status |
|---|---|---|
| 2 | Broken layers + gates | ✅ #132 |
| 2b | Cluster-secret annotations for velero + external-dns | ✅ #133 |
| 16 | Naming/tagging cap-clearers | ✅ #134 |
| 17 | Security batch | ✅ #136 |
| 18 | Testing batch | ✅ #137 |
| 18b | tflint severity gate hardening | ✅ #138 |
| 19 | Docs + agent surface | ✅ #139 |
| 19b | Cluster-bootstrap `monitoring/managed` label | ✅ #140 |
| 24 | Endpoint posture flip (after rackctl target 23) | ☐ |

---

## Target 2 — Broken layers + the gates that let them merge (L)

Findings (all verified by execution):
- `fleet/aws/cluster-bootstrap/main.tf:13` `module "agent_iam"` omits required
  `cluster_name` and `data_kms_key_arn` (`components/aws/agent-iam/variables.tf:73-81`,
  no defaults) — `tofu validate` fails with two missing-argument errors. This root is
  the second Workspace of the eks-fleet spoke vend; the vend path is broken as committed
  (PR #130's agent-iam consolidation never propagated to the wrapper).
- All four `*-platform` live components fail terragrunt evaluation:
  `get_path_relative_to_include("live")` in
  `live/_envcommon/aws/{competitive-intelligence,digest-pipeline,slack-knowledge-bot}-platform.hcl:16-29`
  and `incident-response-platform.hcl:17` — no include labeled `live` exists and the
  function isn't resolvable on terragrunt 1.0.4. Every other envcommon uses plain
  `config_path = "../network"` — adopt that idiom.
- Latent second bug behind it: those files read `dependency.cluster.outputs.cluster_sg_id`
  (`competitive-intelligence-platform.hcl:42`) but the component exports
  `cluster_security_group_id` (`components/aws/cluster/outputs.tf:20`); the mocks mock
  the wrong key so plan-with-mocks can't catch it.
- `mock_outputs_allowed_terraform_commands` restricted to validate/plan in only 4 of 19
  dependency-bearing envcommon files. Concrete hazard: `live/_envcommon/aws/agent-iam.hcl:18-23`
  mocks a KMS ARN with no restriction, and `scripts/e2e.sh:231-241` applies
  network → cluster → cluster-bootstrap → agent-iam without applying `secrets` — a fresh
  account bakes the mock ARN into real SSE-KMS config (`components/aws/agent-iam/artifacts.tf:132-141`)
  and an IAM policy (`main.tf:238-251`).
- CI never evaluates terragrunt or `fleet/`: the plan job is `continue-on-error: true`
  and conditional on `vars.AWS_ROLE_ARN` (`.github/workflows/ci.yml:180,210-227`);
  validate/tflint/checkov glob `components/aws` only (`ci.yml:57,150,159`).

Approach:
1. Fix the fleet root: wire `cluster_name` and `data_kms_key_arn` through
   `fleet/aws/cluster-bootstrap` variables (trace where the vend supplies the data CMK —
   the secrets component output in the spoke account; follow the live-tree wiring
   `dependency.secrets.outputs.kms_key_arn` as the reference).
2. Fix the four platform envcommon files: plain relative `config_path` idiom + the
   `cluster_security_group_id` key (both the dependency read and the mocks).
3. Restrict mocks to `["validate", "plan"]` in all 19 dependency-bearing envcommon files.
4. Add `scripts/check-mock-outputs.py`: cross-check every `mock_outputs` key against the
   target component's `outputs.tf`; wire into CI so a renamed output fails the build
   instead of hiding behind a mock.
5. CI gates: add a credential-less terragrunt evaluation job (`terragrunt render` or
   equivalent per leaf across the live tree — the four platform leaves must fail before
   the fix and pass after); extend validate/tflint/checkov matrices to `fleet/aws/*`
   and `modules/aws/*`.
6. e2e ordering: `scripts/e2e.sh` applies `secrets` before `agent-iam` (or asserts the
   dependency is real, not mocked, at apply time).

Acceptance: `tofu validate` green on every `fleet/aws/*` root; `terragrunt render`
green on every live leaf; a deliberately wrong mock key fails CI; four phases green.

## Target 2b — Cluster-secret annotations for velero + external-dns (S)

**Scope discovered by eks-gitops PR #128** (the Target-3 fix for eks-gitops's dead
velero bucket names and unscoped external-dns): both fixes read new annotations off
the ArgoCD cluster registration Secret under `missingkey=error` — `velero/backup-bucket`
and `external-dns/domain-filter`. Neither annotation exists yet. Until this lands, the
new eks-gitops `addons-velero`/`addons-external-dns` ApplicationSets fail to render on
any real cluster.

Findings (verified):
- The ArgoCD cluster Secret is `kubernetes_secret_v1.argocd_cluster` in
  `components/aws/cluster-bootstrap/bootstrap.tf:340-383`. Its `labels` block already
  carries `region`/`cluster_name` (`:349-350`); its `annotations` block already carries
  the precedent for a cross-component-sourced, conditionally-populated value —
  `eks-agent-platform/eval-reports-bucket` reads `data.aws_ssm_parameter.eval_reports_bucket[0].value`
  (`bootstrap.tf:382`, sourced via `components/aws/cluster-bootstrap/main.tf:10-12`
  reading `/eks-agent-platform/${var.cluster_name}/eval-runtime/eval_reports_bucket`).
- The velero bucket is a `cluster-addons` output (`components/aws/cluster-addons/outputs.tf:23`,
  `module.velero_bucket[0].s3_bucket_id`) — `cluster-addons` runs before
  `cluster-bootstrap` in the documented dependency chain (landing-zone/CLAUDE.md:
  `network → cluster → {..., cluster-addons, cluster-bootstrap}`), so the value is
  available; it just isn't published anywhere `cluster-bootstrap` can read it yet.
- No domain/zone variable exists anywhere in the repo for external-dns to filter on.
  `components/aws/dns` is the component that owns Route53 (verified: `main.tf`/`outputs.tf`
  reference `aws_route53_zone`) — check what it outputs (a zone name, most likely) as
  the source for the new annotation.

Approach:
1. Publish the velero bucket name from `cluster-addons` to SSM at
   `/eks-agent-platform/${var.cluster_name}/cluster-addons/velero_bucket` (mirror the
   eval-reports-bucket idiom exactly — conditional on velero being enabled), then read
   it in `cluster-bootstrap/main.tf` the same way `eval_reports_bucket` is read, and add
   `"velero/backup-bucket" = data.aws_ssm_parameter.velero_bucket[0].value` to the
   `argocd_cluster` Secret's annotations block, conditional on velero being enabled for
   that environment (staging/production only, matching eks-gitops's own gating).
2. Determine what `components/aws/dns` actually outputs (a zone name is the likely
   shape) and publish/read it the same way for
   `"external-dns/domain-filter" = <zone-name>`, scoped per environment the way `dns`
   already is.
3. If either cross-component read reveals `cluster-addons` or `dns` don't yet run before
   `cluster-bootstrap` in every live leaf that needs this (verify against the live tree,
   not just the documented chain), fix the dependency ordering — do not add a manual
   apply-order workaround.

Acceptance: `tofu validate` + `tofu plan` (credential-less where possible; note if a
live plan needs real credentials and what was verified vs skipped) shows the two new
annotations populated on a staging/production cluster secret and absent/inapplicable on
dev; `terragrunt render` clean; open an issue or note in this file if `components/aws/dns`
turns out not to expose a per-environment zone at all (in which case this target's
external-dns half is blocked on a real product decision, not an implementation detail —
stop and flag it rather than inventing a zone).

Outcome (✅ #133): **both halves shipped.** `components/aws/dns` does expose a usable
per-environment zone — its `domain_name` output (each leaf sets a distinct
`development.example.com` / `staging.example.com` / `example.com`), so the external-dns
half was not blocked. velero publishes from `cluster-addons` to
`/eks-agent-platform/<cluster-name>/cluster-addons/velero_bucket`; dns publishes
`domain_name` to `/eks-agent-platform/<environment>/dns/domain_filter` (keyed on the
environment — dns has no cluster identity). `cluster-bootstrap` reads both back behind
`enable_velero_backup` / `enable_external_dns` (default false) and stamps the two
annotations. Ordering fix beyond the documented chain: `cluster-addons`, `dns`, and
`cluster-bootstrap` were unordered siblings under `cluster`, so a fresh
`terragrunt run --all` could read the SSM params before their producers wrote them —
each enabling leaf now declares a `dependencies` block ordering the producers first
(development: `../dns`; staging/production: `../cluster-addons` + `../dns`; hub: none,
carries neither annotation).

## Target 16 — Naming/tagging cap-clearers (L)

Findings (verified):
- REJECT (code_quality cap): `variable "team"` described as "drives tagging + ArgoCD
  AppProject scope" while `var.team` is referenced nowhere —
  `components/aws/incident-response-platform/variables.tf:79-82`,
  `slack-knowledge-bot-platform/variables.tf:118-121`,
  `digest-pipeline-platform/variables.tf:93-96`,
  `competitive-intelligence-platform/variables.tf:76-79`. Also stale
  `default = "protohype"` (retired incubator name) — fix the default to each app's
  real owning team.
- Consistency cap 1 (`bucket-global-uniqueness`, reject): tenant/platform bucket names
  embed no account id — `pipeline/modules/tenant/data_lake.tf:26,64,97`,
  `llm/modules/tenant/model_storage.tf:22`, `mlops/modules/tenant/storage.tf:26,64`,
  `rag/modules/tenant/document_storage.tf:16`, `druid/modules/tenant/storage.tf:9,33,67`,
  `governance/modules/tenant/guardrail_bucket.tf:5` + `audit_storage.tf:23`,
  `incident-response-platform/s3.tf:12`, `slack-knowledge-bot-platform/s3.tf:11`,
  `digest-pipeline-platform/s3.tf:17,65` — while `agent-iam/artifacts.tf:29-31`,
  `cost/main.tf:88`, `org-cost/main.tf:173`, `org-compliance/config.tf:74` do it right.
- Consistency cap 2 (`no-doubled-env`, reject): no validation block anywhere rejects a
  caller-supplied base name equal to the environment token (charset regexes only, e.g.
  `agent-iam/variables.tf:10`).
- Env-first grammar inverted ×4: `prefix = "incident-response-${var.environment}"`
  (`incident-response-platform/main.tf:22` + siblings) vs env-first everywhere else —
  and internally inconsistent with the same components' env-first role lookups
  (`irsa.tf:129`).
- 4× copy-pasted Pod Identity association + `app_access` policy shell
  (`incident-response-platform/irsa.tf:128-142`, `slack-knowledge-bot-platform/irsa.tf:115-129`,
  `digest-pipeline-platform/irsa.tf:92-106`, `competitive-intelligence-platform/irsa.tf:62-76`)
  — extract `modules/aws/platform-app` (or similar), four real consumers earn it.
- `modules/aws/workload-identity/` has no `versions.tf`.
- `.tflint.hcl` at root is dead config (CI/Taskfile use `.tflint-aws.hcl` only);
  `live/aws/fleet/account.hcl:2` and `live/aws/workload-production/account.hcl:2` share
  placeholder `333333333333` — de-dupe.

Approach:
1. Wire `Team = var.team` into each platform component's tag locals (clears the REJECT
   and the required-tier tagging violation in one line per component); fix defaults.
2. Bucket renames per U4 (nothing live — straight rename): follow the agent-iam idiom
   (account id embedded). **Run the real AWS length math first**: 63-char S3 limit vs
   `env(≤11) + component + tenant_id(≤24) + account(12) + purpose + separators` — if the
   budget doesn't close, tighten the `tenant_id` cap with a validated error message
   carrying the arithmetic (the repo's established style), and add/extend lifecycle
   preconditions like `agent-iam/artifacts.tf:47-50`.
3. `no-doubled-env` validation blocks at the variable boundary wherever a base name
   composes with `var.environment` (cluster name already has the != rule via the
   standard — mirror it for tenant/component name inputs).
4. Normalize the four platform components to env-first prefixes; extract the shared
   module; add `versions.tf` to workload-identity; delete `.tflint.hcl`; de-dupe the
   account placeholders.
5. Undescribed variables/outputs: `llm/modules/tenant/variables.tf` (6),
   `gateway/modules/tenant/variables.tf` (3), `gateway/modules/tenant/outputs.tf` (4).

Acceptance: `tofu test` suites green (extend the naming-guard tests to prove the new
validations fire via `expect_failures`); grep shows no account-id-less bucket resource;
four phases green.

## Target 17 — Security batch (L)

Findings:
- `components/aws/cluster-addons/irsa.tf:378-383`: argo-events grants `sqs:*` + `sns:*`
  on `*` — scope to resource ARN patterns + conditions (HIGH).
- `cluster-addons/irsa.tf:122,143-154`: ALB controller mutating EC2/ELB actions on `*`
  without the upstream reference policy's `elbv2.k8s.aws/cluster` tag conditions — adopt
  the upstream conditions.
- `gateway/modules/tenant/irsa.tf:31,39`: disabled-feature fallback grants
  (`Resource = enabled ? [arn] : ["*"]`) for cognito-idp admin actions and
  `wafv2:UpdateWebACL` — use the omit-the-statement pattern the llm/mlops siblings use.
- `pipeline/modules/tenant/irsa.tf:173-187`, `druid/modules/tenant/irsa.tf:69-81,110-125`:
  `kafka-cluster:*Data/Connect/CreateTopic/AlterGroup` on `*` though the verbs support
  resource ARNs and MSK is tenant-provisioned — scope them; correct the inaccurate
  `.checkov.yaml` rationale and narrow the blanket CKV_AWS_355/290/63 skips to the
  telemetry/describe cases that genuinely need `*`.
- `break-glass/main.tf:69-85`: boundary's `DenyIAMModifications` omits
  `iam:CreateAccessKey`, `iam:AttachUserPolicy`, `iam:PutUserPolicy`,
  `iam:CreatePolicyVersion`, `iam:UpdateAssumeRolePolicy`,
  `iam:PutRolePermissionsBoundary`, `sts:AssumeRole` — add them (session persistence /
  escalation under AdministratorAccess).
- State buckets (`fleet-hub/main.tf:92`, `portal-hub/main.tf:48`): AES256 → SSE-KMS,
  add deny-insecure-transport + access logging (highest-value data in the repo's blast
  radius).
- KMS condition parity: `secrets/main.tf:40-45` and `org-compliance/main.tf:49-54`
  missing the `SourceAccount`/`ViaService` conditions their sibling statements carry.
- App buckets without TLS-deny: `digest-pipeline-platform/s3.tf:16,64`,
  `incident-response-platform/s3.tf:11`, `slack-knowledge-bot-platform/s3.tf:10` —
  seed `DenyInsecureTransport` (same baseline eks-agent-platform PR #88 established).
- SNS topics unencrypted (8, currently a documented posture skip) — add KMS; it's cheap.

Approach: work component-by-component; every narrowed policy gets/extends a `tofu test`
assertion (the repo's invariant-test idiom); update `docs/threat-model.md` residuals
that these fixes retire.

Acceptance: checkov green with the narrowed skip file; extended tftest suites prove the
new denies/conditions; four phases green.

Outcome (✅ #136): **all nine findings shipped.** Resolutions and scope discovered:

- **`workload-identity` silently dropped Conditions.** Its `policy_statements` type
  had no `Condition` attribute, so the ALB tag conditions would have been ignored at
  the module boundary (caught by `tofu validate`, not just review). Added
  `Condition = optional(map(map(string)))` + a null-stripping render local. All IAM
  conditions passed through the module are `map(map(string))`; `optional(any)` does
  NOT work (heterogeneous condition shapes can't unify for a `list(object)`). If a
  future caller needs a list-valued or non-string condition through this module, the
  type needs widening.
- **checkov narrowing was rationale-only, not skip-removal.** CKV_AWS_355/290/63 fire
  on ~40 resources across the repo (every IRSA role with a telemetry/describe grant,
  plus the boundary ceilings) — and the workload-identity module policy is a single
  shared resource, so per-consumer inline skips are impossible. Kept them as global
  skips but corrected the rationale (dropped the false kafka-cluster claim) and
  removed CKV_AWS_26 outright (all SNS now encrypted). Net checkov: 827/82/7
  passed, 0 failed, 0 parsing errors.
- **argo-events scoped to account/region, not a per-cluster prefix.** The finding
  suggested a per-cluster ARN prefix, but argo-events' event-source queue/topic
  names aren't contractually cluster-prefixed in this repo; a hard prefix match would
  silently break sensors consuming differently-named queues. Scoped to
  `arn:…:sqs:<region>:<account>:*` / `sns` + narrowed verbs instead — removes the
  cross-account/admin surface without assuming a naming convention.
- **SNS encryption needed per-component CMKs, not `alias/aws/sns`.** Every topic is
  published to by an AWS service (CloudWatch Alarms, EventBridge, Cost Anomaly,
  GuardDuty/Security Hub, AWS Backup); the AWS-managed key can't grant those service
  principals, so each component got a dedicated CMK whose policy admits its
  publishers (SourceAccount-scoped). "Cheap" monetarily, but it's 6 new CMKs.
- **incident-response s3.tf docstring was inaccurate** — it claimed the operator
  manages that bucket's policy, but `eks-agent-platform`'s `ensureBucketPolicy` only
  touches the shared `ArtifactsBucketName` (its own comment says "terraform does not
  own this bucket's policy"). Corrected the comment inline; the app buckets have no
  operator-managed policy, so the terraform TLS-deny is conflict-free.
- **Access logging added a sibling log bucket per state bucket** (SSE-S3, its own
  TLS-deny, `logging.s3.amazonaws.com` grant scoped by SourceArn/SourceAccount).

**Rolls into Target 18 (testing):** this target added `role_policy_json` output
plumbing to cluster-addons and the gateway/pipeline/druid tenant modules + roots (the
rag idiom) — Target 18's tenant-IRSA suites should build on these. Target 17 tested
every IAM/KMS/bucket-policy *deny/condition* it introduced; the pure resource-attribute
changes on the remaining four SNS topics (cost, observability, service-quotas, backup)
and the three app-bucket TLS-deny policies are asserted representatively (break-glass +
org-security SNS, the fleet/portal state-bucket policies) but their per-component
attribute coverage folds into Target 18's broader suite work.

## Target 18 — Testing batch (M)

**Findings from Target 17 (PR #136):**
- `modules/aws/workload-identity`'s `policy_statements` variable type had no `Condition`
  field at all — meaning any IAM condition passed through this module was silently
  dropped before Target 17 fixed it (`Condition = optional(map(map(string)))` + a
  null-strip render). `optional(any)` does NOT work here — heterogeneous condition value
  shapes can't unify for a `list(object)`. If this batch's tenant-IRSA test work touches
  a condition whose value isn't a plain string/list, the module's type will need
  widening again — check this before assuming a condition silently applies.
- Target 17 added `role_policy_json` output plumbing to `cluster-addons` and the
  gateway/pipeline/druid tenant modules + roots, following the existing `rag` module's
  idiom. **Build this batch's tenant-IRSA test suites on those outputs** rather than
  re-deriving a way to assert on rendered policy JSON from scratch.
- Target 17 tested every IAM/KMS/bucket deny/condition it introduced directly, but
  per-component attribute coverage is only representative for: the 4 SNS topics it
  didn't directly test (cost/observability/service-quotas/backup — all got SSE-KMS, not
  all got a dedicated assertion) and 3 app-bucket TLS-denies. Close that gap here.

**Finding from Target 16 (PR #134):** `terraform_documented_variables`,
`terraform_documented_outputs`, `terraform_unused_declarations`, and
`terraform_required_providers` are all warning-severity tflint rules, but CI runs
`--minimum-failure-severity=error` — so these rules never actually fail a build, which
is why Target 16 found undescribed variables tflint should have caught. Either raise
these to error severity (if the repo's real state can pass at that bar today) or add an
explicit, justified allowlist for any residual violations — don't leave a
silently-toothless lint gate. Known residuals at time of writing: `secrets/variables.tf`
unused `cluster_name`, `secrets/main.tf` missing a `random` provider constraint,
`service-quotas/variables.tf` unused `region`, `slack-knowledge-bot-platform/variables.tf`
unused `audit_ttl_days`.

Findings: `fleet-hub` (management-account twin of tested fleet-vend) has no suite;
6 of 7 tenant-IRSA modules untested (only `rag/tests/` exists); drift watch covers 8 of
23 production components via a hardcoded matrix (`.github/workflows/drift.yml:38-45`)
and only production; no `concurrency:` on ci/deploy/destroy/drift workflows (only
`e2e.yml:41`); no `task test` entry point; plan job soft (`ci.yml:180` — also touched in
target 2).

Approach: fleet-hub tftest mirroring fleet-vend's invariants; a shared tenant-IRSA test
pattern stamped across the 6 uncovered modules (boundary, scoping, naming guards); drift
matrix auto-discovered from the live tree (mirror ci.yml's discovery) and extended to
staging; `concurrency:` groups keyed on env/component for the mutating workflows;
`task test` running the tftest suites locally; make the plan job fail honestly when
`vars.AWS_ROLE_ARN` is configured (keep the fork-safe skip when absent).

Acceptance: `task test` green locally; drift workflow lists every applied production +
staging component; two dispatched deploys on one env serialize.

Outcome (✅ #137): **all seven assigned items shipped, `task test` green across 26
suites (all 3 trees, `terragrunt render` still 100% clean).** Resolutions + scope
discovered:

- **fleet-hub IAM ceiling suite added as a second file** (`fleet-hub-iam.tftest.hcl`),
  mirroring fleet-vend's four invariants (web-identity trust bound to the crossplane SA,
  boundary DenyUnboundedRoleWrites + DenyEscalation, identity role-write boundary-gated +
  path-scoped). It uses the real credential-less provider (skip_* + override_data) — the
  hub trust is a `data.aws_iam_policy_document` a mock provider mangles. The existing
  `fleet-hub.tftest.hcl` (state-bucket SSE/TLS, mock provider) stays as-is; the two files'
  provider choices are each the right tool for what they assert.
- **Only llm + mlops actually lacked tenant-IRSA tests** (Targets 16/17 had already added
  suites to druid/pipeline/gateway/governance). Added full scoping + omit-toggle + naming
  guard suites for both; surfaced `*_policy_json` outputs on their tenant modules + roots
  (the rag/druid idiom, since neither had `role_policy_json`). Added no-doubled-env guard
  runs to druid/pipeline/gateway (they had scoping but no naming-guard run).
- **App-platform TLS-deny: digest needed the real-provider strategy.** incident-response
  and slack plan clean under a mock provider (with the pod-identity tenant role + Aurora
  master-secret block mocked). digest's SES identity exposes a purely-computed
  `dkim_signing_attributes` block an output indexes `[0]` into — a mock renders it empty
  (plan fails) and it can't be overridden (not in config), so digest uses the real
  provider (computed → unknown, so the index is harmlessly unknown) with the two bucket
  ARNs pinned via `override_resource`.
- **SNS suites assert both the dedicated-CMK SSE wiring and that the key policy admits
  the publishing service principal** (SourceAccount-scoped) — the reason a dedicated CMK
  was required over `alias/aws/sns`. Needed valid-ARN mocks for the CMK/topic (and the CE
  monitor / backup role) so the alarms/subscriptions plan.
- **drift auto-discovery verified against the live tree:** the discover job now emits
  every production + staging leaf (23 + 23 = 46, up from the hardcoded 8 production-only),
  confirmed by running the jq matrix locally against `git ls-files`.
- **Mutating-workflow concurrency uses a shared `mutate-<env>-<component>` group across
  deploy.yml AND destroy.yml** (cancel-in-progress false) — so two deploys, two destroys,
  OR a deploy racing a destroy of the same target all serialize.

**Scope discovered — the "Finding from Target 16" tflint-severity item is ~10× its
stated size and is carved out.** The note listed ~4 residuals; the real inventory at
error-off is ~40 warnings: `terraform_unused_declarations` dominates (~30), almost all
from the deliberate uniform-interface variables every component declares for envcommon
(`region`/`environment`/`vpc_id`/`cluster_sg_id`) even when a given component doesn't
reference them, plus 7 components missing `terraform_required_version` /
`terraform_required_providers` constraints. The two rules that actually caused Target
16's miss — `terraform_documented_variables` / `terraform_documented_outputs` — already
pass clean today. Making the gate hard needs an interface-variable-contract decision
(keep the uniform interface and allowlist unused-declaration on those four vars, or trim
+ rewire envcommon) plus a `versions.tf` backfill — a design-bearing change, not a
mechanical testing fix, and unsafe to bundle unreviewed into a testing PR. Recommend a
dedicated bounded lint-gate-hardening target (sibling to Target 19's gate work).

## Target 18b — tflint severity gate hardening (S)

**Scope discovered by Target 18 (PR #137) — see its own "Scope discovered" note above
for the full inventory.** Decision (made here, not escalated — bounded and mechanical
once split correctly):

1. **`terraform_required_version` / `terraform_required_providers`: raise to error.**
   No design question — 7 components are missing the constraint outright. Backfill a
   `versions.tf` matching the repo's existing 36-component pattern
   (`>= 1.11.0`, `aws ~> 6.0`) for each. Mechanical, do it, raise the rule.
2. **`terraform_documented_variables` / `terraform_documented_outputs`: raise to error.**
   Already pass clean today (confirmed by Target 18) — this is free, just flip the
   severity so a future regression can't slip through the way Target 16's did.
3. **`terraform_unused_declarations`: raise to error, WITH a scoped, documented
   exception for the uniform envcommon interface.** The repo's own convention
   (`landing-zone/CLAUDE.md`: "Dependency wiring lives in `live/_envcommon/aws/{name}.hcl`,
   not in the component itself") is why every component declares the same interface
   variables (`region`/`environment`/`vpc_id`/`cluster_sg_id`) even when a specific
   component doesn't reference one — that's the uniform envcommon contract working as
   designed, not dead code. Do NOT trim these or rewire envcommon per-component (that
   would be the disruptive option and gets worse the interface, not better). Instead:
   scope a tflint-level exception (inline `# tflint-ignore` comments on the four known
   interface variables, or a rule-config exclusion if tflint supports pattern-based
   scoping) with a comment explaining the uniform-interface rationale — the same
   narrowed-skip-with-rationale idiom Target 17 already established for checkov. This
   makes the rule catch genuine dead code (a variable nothing anywhere references) while
   not fighting the repo's own documented convention.

Approach: implement in the order above (1 and 2 are trivial; 3 needs the scoped
exception mechanism worked out — check tflint's plugin docs for the right suppression
primitive, don't invent a workaround if a native one exists). Run the full tflint suite
at error severity afterward and confirm 0 unexplained failures — every remaining
suppression must carry a rationale comment, mirroring `.checkov.yaml`'s style.

Acceptance: `task lint`/CI's tflint step at `--minimum-failure-severity=error` passes
clean; a deliberately unused, non-interface variable introduced in a test component
fails the gate (prove the rule is live, not just suppressed into silence); every
suppression in the config or inline has a one-line rationale.

Outcome (✅ #138): **shipped; mechanism and dead-code inventory both differed from
the plan's model.** Resolutions + scope discovered:

- **"Raise to error" isn't achievable — tflint rule severities are fixed per rule,
  not configurable.** Confirmed empirically and against tflint's config docs (a rule
  block accepts only `enabled`/`ignorable`, no `severity`). The documented-*/naming
  rules emit at `notice`, unused-declaration and required-version/providers at
  `warning`; the only lever is the runner's `--minimum-failure-severity`. Lowered it
  to `notice` (not `error`, not `warning`) in `ci.yml` + `Taskfile.yaml` so the
  `notice`-level documented-* rules — the exact class that let Target 16's undescribed
  variables through — also hard-fail. Verified at `notice` the whole tree's only
  findings are the three in-scope rules (no aws-plugin/naming surprises).
- **The dead-code half was ~4× the plan's estimate.** Beyond the ~31 uniform-interface
  findings, `terraform_unused_declarations` flagged 18 genuinely-dead declarations, not
  ~4: seven non-interface variables (`cost/cur_report_prefix`,
  `observability/{slack_webhook_url,log_retention_days}`, two
  `incident-response-platform` TTL vars, `slack-knowledge-bot-platform/audit_ttl_days`
  — three of them set with real per-env values in `live/` yet never consumed) plus
  eleven unused locals and the `aws_caller_identity`/`aws_region`/`aws_partition` data
  sources that only fed them. All removed (with their inert `live/` inputs), not
  suppressed — the acceptance test mandates non-interface unused vars fail the gate.
- **`cluster_name` is a fifth uniform-interface variable.** The plan named four
  (`region`/`environment`/`vpc_id`/`cluster_sg_id`); `secrets/cluster_name` is wired
  identically by 17 `_envcommon` files, so it got the same documented ignore rather
  than removal (removing it would make `secrets` the odd component out — the "gets
  worse the interface" outcome the decision warned against).
- **`github-oidc`'s test broke on the data-source removal.** Its suite `override_data`'d
  the `aws_caller_identity` read that `local.account_id` (unused) fed; the override was
  vestigial (the trust-policy account-qualified ARN comes from the OIDC-provider
  override, not caller-identity). Dropped the override + fixed its comment; the five
  security assertions are unchanged and pass.

## Target 19b — Cluster-bootstrap `monitoring/managed` label (S)

**Scope discovered by eks-gitops Target 21 (PR #130).** That target made opencost gate
on a new dedicated label, `monitoring/managed`, instead of overloading
`eks-agent-platform/enabled` as a monitoring proxy. Nothing produces this label yet —
`cluster-bootstrap` currently stamps `monitoring/amp-workspace-id` as an *annotation*
only, under `var.enable_managed_monitoring` (`components/aws/cluster-bootstrap/bootstrap.tf`,
near line 383), with no corresponding *label*. This is the same producer/consumer gap
pattern as Target 2b (velero/external-dns annotations) — a small, well-scoped addition,
not a design question.

Approach: add `"monitoring/managed" = "true"` to the `argocd_cluster` Secret's `labels`
merge block in `cluster-bootstrap/bootstrap.tf`, conditional on
`var.enable_managed_monitoring` the same way the existing annotation is gated. Confirm
against eks-gitops' `applicationsets/addons-opencost.yaml` (read that repo, don't
guess) that the label key/value this target produces is exactly what the selector there
expects.

Acceptance: `tofu validate` + `terragrunt render` clean (should remain the established
100%); a cluster with managed monitoring enabled carries the label, one without does
not; note in this file if the eks-gitops selector turns out to expect a different
value than `"true"` and fix to match rather than asking eks-gitops to change.

Outcome (✅ #140): **shipped; the selector expects exactly `"true"`, no mismatch.**
Confirmed against `eks-gitops/applicationsets/addons-opencost.yaml` — its clusters
generator matches `monitoring/managed: "true"` (alongside
`argocd.argoproj.io/secret-type: cluster`). Added `"monitoring/managed" = "true"` as a
fourth `var.enable_managed_monitoring`-gated merge clause on the `argocd_cluster`
Secret's `labels`, sharing the exact gate that already stamps the `monitoring/*`
annotations (grafana-url, amp-endpoint, amp-workspace-id) opencost reads — so an
opencost-selected cluster always carries the AMP workspace-id annotation opencost
templates its `workspaceId` from, and a cluster without managed monitoring carries
neither. cluster-bootstrap had no `tofu test` suite (the only component lacking one);
added `tests/cluster-bootstrap.tftest.hcl` (mocked aws/kubernetes/helm/kubectl
providers, `command = plan`) proving the label is present-and-`"true"` with managed
monitoring on and absent with it off, and asserting the label/annotation coupling in
both directions. `tofu validate`, `task lint` (notice), `task evaluate` (all live
leaves), and `task fmt:check` all clean.

## Target 19 — Docs + agent surface (M)

Findings:
- `README.md:6` MIT badge vs Apache-2.0 LICENSE.
- `AGENTS.md:13` cites nonexistent module `eks-cluster-baseline`; `AGENTS.md:53` edit
  residue ("must include both … (current)" with one item).
- `CONTRIBUTING.md:39-45` include snippet doesn't match the real pattern
  (`find_in_parent_folders("root.hcl")`, `"cloud.hcl"`-anchored envcommon path,
  `merge_strategy = "deep"` — see any live leaf) and fails on terragrunt 1.0.4;
  `CONTRIBUTING.md:30` documents pre-standard naming grammar — align with env-first.
- `docs/first-deploy-aws.md:159` `--name <env>-eks` → the cluster is `<env>-platform`.
- `docs/runbooks.md:23,181,211,239` + `docs/troubleshooting.md:19`: `task` commands omit
  `ACCOUNT`, defaulting to workload-development → nonexistent paths for other envs.
- `docs/runbooks.md:207` (RB-005): account id lives in `account.hcl`, not `env.hcl`.
- `README.md:113-120` + CLAUDE.md say four workflows; five exist. `docs/operations.md:82-86`
  omits the test + placeholders gates; `operations.md:26-27` documents deploying
  management/org via workflow but `deploy.yml:16-23` only offers dev/staging/prod —
  document the local-only envs as such.
- `Taskfile.yaml:83` `init-backend` passes no args to a script that requires two
  (`scripts/init-backend-aws.sh:7-8`) — fix the task (and drop the
  `first-deploy-aws.md:294` troubleshooting entry that documents the breakage).
- `Taskfile.yaml:36` validate loop discards init stderr — keep failure abort, surface
  the error output.
- All five `.claude/skills` invoke `make` targets that don't exist and allowlist
  `Bash(make *)` — rewrite to the real `task` commands (with required ACCOUNT/REGION
  vars) and fix `allowed-tools` frontmatter: `validate/SKILL.md:5,10-15`,
  `plan/SKILL.md:6,9,18`, `drift/SKILL.md:6,17`, `add-component/SKILL.md:47` (+ the
  fifth, add-tenant — verify).

Acceptance: every documented command copy-paste-executes from a clean checkout (spot-run
them); skills invoke real tasks; badge matches LICENSE.

Outcome (✅ #139): **all findings shipped; verified against the current tree (Targets
2/16/17/18/18b had shifted several line numbers and a few facts since the finding list
was written).** Spot-ran the credential-less gates on the real tree: `task fmt:check`,
`task validate` (all roots valid), `task lint` (clean at `notice`), `task evaluate`
(every live leaf renders on terragrunt 1.0.4), and `task init-backend --dry` (both args
forward). The corrected CONTRIBUTING include snippet is the exact pattern every live
leaf already uses, so `task evaluate` passing is proof it evaluates.

Scope discovered beyond the finding list (fixed here, same docs-truth sweep):
- **The `destroy` skill was a sixth skill the list didn't name** — it invoked terragrunt
  against stale `live/<env>/<component>/` paths. Repointed to the real
  `live/aws/<account>/us-west-2/<env>/<component>/` layout, wired its final step to
  `task destroy`, and added `allowed-tools` frontmatter.
- **`add-tenant` carried the same stale `live/<env>/…` path** and a `components/<name>/`
  (vs `components/aws/<name>/`) reference — corrected both.
- **`troubleshooting.md`'s "Component Not in CI Plan Matrix"** told readers to hand-edit
  ci.yml matrices and deploy/destroy "allowlists" — both obsolete since Target 2's
  git-ls-files auto-discovery and the free-form component inputs. Rewrote to the
  track-the-files reality.
- **`operations.md`'s CI/CD table and drift scope** were pre-Target-2/18: added the
  placeholders/test/evaluate/mock-outputs gates, the widened fmt (adds `fleet/` +
  `terragrunt hcl format`) and checkov (adds `fleet/aws` + `modules/aws`) scope, and
  changed drift from "production, 8 hardcoded components" to "production + staging,
  matrix auto-discovered".

Nothing observed relevant to Target 19b (the `monitoring/managed` label producer gap) or
Target 24 (endpoint posture, blocked on rackctl #23) — both remain untouched by this
docs pass.

## Target 24 — Endpoint posture flip (S — only after rackctl target 23 ships)

Findings: committed `cluster_endpoint_public_access = true` with no CIDRs trips the
component's own fail-closed validation (`components/aws/cluster/variables.tf:97-100`) —
`live/aws/workload-development/us-west-2/development/cluster/terragrunt.hcl:11` and
`live/aws/fleet/us-west-2/hub/cluster/terragrunt.hcl:20-22` (CIDRs commented out).
Also the posture inversion: staging private while production public.

Approach (decision U3): remove the hardcoded public-access flags from the committed dev
and hub leaves — the committed tree is private-by-default and plans clean everywhere;
posture becomes a rackctl-supplied input (`TF_VAR_cluster_endpoint_public_access` +
`TF_VAR_cluster_endpoint_public_access_cidrs` at `init --apply`, egress-IP autodetect).
The component's fail-closed validation stays exactly as-is — it's the guard that makes
the env-supplied path safe. Document the input pair and the rackctl path in
`docs/inputs.md` (and the first-deploy walkthrough where endpoint access is discussed).

Acceptance: `terragrunt plan` on dev + hub cluster leaves succeeds from the committed
tree (private); with the two TF_VARs exported, plan shows public + allowlist; docs name
rackctl as the owner of the fragile input.

## Additional scope discovered mid-campaign (not yet assigned a target)

**`tenants-protohype` namespace default — resolved as unrelated to eks-gitops'
`protohypd`, still stale on its own merits (found by Target 16, PR #134; cross-repo
question closed by eks-gitops Target 21, PR #130).** The four `*-platform` components'
`namespace` variable still defaults to `tenants-protohype`. eks-gitops Target 21
confirmed this is a **different** retired-codename identity than `protohypd` (which was
an unrelated example-tenant name on the `ops` Platform, renamed to `platform-ops`) — no
cross-repo coordination is needed, that question is closed.

What's still genuinely open: `tenants-protohype` is the shared namespace default for the
four promoted protohype-team apps (competitive-intelligence, digest-pipeline,
incident-response, slack-knowledge-bot), but eks-gitops' `apps-tenants` ApplicationSet
now provisions per-app `tenants-<app>` namespaces, not one shared namespace — so this
default doesn't match the namespace shape the consuming side actually uses. Low
urgency: not a cap, not broken CI, and (per Target 2's findings) these four components'
live wiring has its own open questions independent of this. Worth a small dedicated
target whenever this repo's queue is revisited — rename the default to match the
per-app `tenants-<app>` convention, verified against what the operator/Platform CR
actually reconciles against before changing it.
