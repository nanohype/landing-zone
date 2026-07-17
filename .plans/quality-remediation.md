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
| 2 | Broken layers + gates | ☐ |
| 2b | Cluster-secret annotations for velero + external-dns | ☐ |
| 16 | Naming/tagging cap-clearers | ☐ |
| 17 | Security batch | ☐ |
| 18 | Testing batch | ☐ |
| 19 | Docs + agent surface | ☐ |
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

## Target 18 — Testing batch (M)

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
