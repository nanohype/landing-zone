# Threat Model

STRIDE analysis of the landing-zone substrate, organized by trust boundary. Each
boundary lists its primary threats, the mitigation **already in this repo** (with
the component that implements it), and the residual risk a fork should weigh.

This is the security reasoning behind [architecture.md](architecture.md)'s
Security Model section, pulled out so it can be reviewed on its own. It is a
model of the *substrate*; in-cluster workload posture lives in the eks-gitops
Kyverno policies and the eks-agent-platform operator.

## Trust boundaries

```
GitHub Actions ──OIDC──► AWS account ──► Terraform state (S3)
                              │
                              ├─► EKS control plane (public? IP-allowlisted)
                              │       │
                              │       └─► workloads ──Pod Identity/IRSA──► AWS APIs
                              │
                              ├─► org guardrails (SCPs) ── management account
                              └─► cross-account fleet vend (boundary + path gated)
```

## 1. CI/CD → AWS  (`github-oidc`)

- **Spoofing** — a foreign workflow assuming the deploy role. Mitigated: the
  trust policy names each repo AND the contexts it trusts within that repo —
  `repo:<org>/<repo>:environment:development`, `...:environment:staging`,
  `...:environment:production` and `...:environment:e2e` by default, the
  environments the deploy, destroy and e2e workflows declare, and each account's
  leaf narrows that to the environments deploying into it. Naming the repo
  alone, with a wildcard claim suffix, would satisfy "repo-scoped" while also
  trusting `pull_request` and every branch — so a fork's pull request against a
  public repo could assume the role. `allowed_subject_claims` is therefore an
  allowlist: every entry must be an exact `environment:<name>` claim. A wildcard
  environment claim is refused because GitHub creates an environment, with no
  protection rules, the first time a workflow names it, so `environment:prod*`
  admits whatever `prodx` a branch's workflow invents. `pull_request` and `ref:`
  claims are refused because anyone able to open that pull request or push that
  ref holds them. `environment:plan` and `environment:drift` are refused in every
  letter case: the PR plan job declares the first and the drift jobs the second,
  and both belong to the read-only plan role.
  `github_org` and `github_repos` must be literal names, because a wildcard there
  (`landing-zone*`) would match `...:environment:plan` past every claim check.
  `github_repos` and `allowed_subject_claims` are both validated non-empty,
  because an empty list on either drops the `sub` condition entirely and lets
  *any* Actions token assume the role. No long-lived keys; OIDC federation only.
  Residual: the trust names environments, not refs. A job that declares an
  environment presents only `environment:<name>` in its `sub`, whatever branch,
  tag or same-repo pull request it runs from, and `deploy.yml`, `destroy.yml` and
  `e2e.yml` run on `workflow_dispatch`, which anyone with write access can start
  from any branch. So every trusted environment is only as narrow as its own
  settings: each of `development`, `staging`, `production` and `e2e` must exist in
  the repository settings with a deployment-branch policy (main, or protected
  branches), and `staging`, `production` and `e2e` should also require reviewers.
  An environment that does not exist yet is created unprotected the first time a
  workflow names it. Confirm those rules before attaching any
  `managed_policy_arns` to the role. The trust also assumes GitHub's default OIDC
  subject template; a customized template changes the `sub` and the role stops
  matching (it fails closed).
- **Elevation of privilege** — the deploy role is powerful. Residual: scope it
  per-environment; do not share one role across development and production. The
  component default lists all four environments as the union across accounts;
  each account's leaf sets `allowed_subject_claims` to its own (the
  `workload-development` leaf trusts `environment:development` and
  `environment:e2e` only), so a job in a less-protected environment cannot reach
  another account's deploy role.
- **Information disclosure** — the read-only plan role. It carries account-wide
  `ReadOnlyAccess`: every S3 object, state files included, and every DynamoDB
  item in the account. Mitigated by tying its trust to the ACCOUNT, which is the
  boundary that matters: the role is account-global and one state bucket holds
  every environment's state, so a leaf's environment directory decides nothing.
  `live/_envcommon/aws/github-oidc.hcl` reads every `env.hcl` under the account
  directory and passes the set as `account_environments` (required, validated
  against the env.hcl vocabulary, and required to contain the leaf's own
  `environment`, which is validated the same way). In an account holding
  `development` alone the plan role trusts `environment:plan` (the
  `plan_allowed_subject_claims` default), which ci.yml's PR plan job declares
  from any branch, including a same-repository pull request's; that is accepted
  for the development account alone. In an account holding `staging` or
  `production` it trusts exactly `environment:drift`, whichever environment
  directory its leaf sits in (`network` and `backup` hold development
  directories beside their production ones): drift.yml declares that
  environment, and its deployment-branch policy admits `main` only, so no pull
  request and no other branch reaches a staging or production account's data.
  There `github_repos` must also be exactly `["landing-zone"]`, because the
  role renders `environment:drift` for every listed repository and only
  landing-zone's `drift` environment carries the branch policy; in another
  repository any branch could create that environment unprotected. An account
  holding neither (management, fleet, shared-services) is refused a plan role.
  The component enforces all of this rather than documenting it:
  `plan_allowed_subject_claims` is an exact-environment allowlist (every entry
  matching `^environment:[^*?]+$`, so no wildcard, `pull_request` or `ref:`
  claim), `environment:plan` is refused in any letter case outside a
  development-only account, and `environment:drift` outside an account holding
  `staging` or `production`. `tofu test` cases in
  `components/aws/github-oidc/tests/` prove each arm, including a leaf in the
  development directory of an account that also holds production. Residual:
  the control is the `drift` environment's branch policy, which lives in
  repository settings, and a branch policy admits by ref. It must exist,
  admitting `main` only, before drift.yml names it, because a workflow naming a
  missing environment creates it unprotected (see
  [operations.md](operations.md#required-before-any-staging-or-production-plan-role)).
  The same holds later: if the environment is ever deleted or renamed, the next
  workflow on any branch that names it recreates it unprotected, and nothing in
  the workflows can see that (reading an environment's branch policy needs a
  token the workflows do not hold). A workflow on `main` that names
  `environment: drift` passes the policy whoever triggered it, which
  `pull_request_target`, `workflow_run` and `issue_comment` triggers would make
  reachable from a pull request or a comment; `scripts/check-drift-workflow.py`
  refuses `environment: drift` in any workflow but drift.yml and any drift.yml
  trigger other than `schedule` and `workflow_dispatch`, so that path needs a
  pull request that fails CI.
- **Information disclosure** — account ids in drift logs and issues. drift.yml
  holds one plan role ARN per account, each carrying a real account id, and the
  plan output it publishes can name its account (the state bucket, role ARNs).
  Mitigated in the logs: the role map is `DRIFT_PLAN_ROLE_ARNS`, a secret on the
  `drift` environment, so the runner prints it as `***` wherever it appears
  whole, and every job that reads it runs `scripts/mask-aws-ids.sh` (the mask
  script every workflow uses) on `DRIFT_PLAN_ROLE_ARNS` as the first command
  of the first step that receives it,
  registering every twelve-digit window and every IAM ARN in it with
  `::add-mask::`. From that line
  on nothing the job prints carries one: not the role step's output, not the
  credential step's `role-to-assume` input, not any later step's env block, and
  not the raw plan output. No job output carries a role value (the runner drops
  a job output containing a masked value, so each `Drift Check` job reads its
  role from the secret itself). `refuse-inherited-config` fails the run if
  `DRIFT_PLAN_ROLE_ARNS` exists as a repository or organization secret or
  variable: a variable is not masked, and a broader secret is readable by every
  workflow and is what the drift jobs would fall back to. Mitigated in the
  issues, which the runner's masking never reaches:
  `scripts/redact-account-ids.py` replaces every id in `DRIFT_PLAN_ROLE_ARNS`
  and every other standalone twelve-digit run before an issue step reads the
  output, and the issue step applies the same rules to the title and body.
  The masking script carries a self-test (synthetic ids) that runs on every
  pull request, and `scripts/check-workflow-id-masking.py` fails a drift.yml in
  which a job reads the secret before the step that masks it, as it does for
  every workflow.
  Residual: masking is by value. An account id that is not in the secret (a
  cross-account reference in plan output) prints in the job log; the issue
  redaction's standalone-twelve-digit pass still removes it from the issue. A
  secret stored across several lines would have each line masked separately,
  so the masking script refuses one and the docs require single-line JSON. With
  step debug logging on, the runner traces each expression's value: a secret is
  masked there, a variable is not, so `refuse-inherited-config` would print a
  repository-level `DRIFT_PLAN_ROLE_ARNS` variable in a debug run; the old
  variable must be deleted, and drift.yml never run with debug logging while
  one exists. The other workflows' ids are held the same way; see
  "account ids and role ARNs in the Actions logs" below.
- **Spoofing** — a workflow assuming the ECR Public pull role. Accepted within a
  bound: this role alone trusts `pull_request`
  (`repo:<org>/<repo>:pull_request` and `repo:<org>/<repo>:ref:refs/heads/main`
  by default), because its policy holds only `ecr-public:GetAuthorizationToken`
  and `sts:GetServiceBearerToken`. The token they mint reads public repositories,
  which any anonymous client can read already; a pull request that obtains it
  gains the account's pull quota, never access. GitHub issues no OIDC token to a
  fork's pull request, so forks pull anonymously.
- **Repudiation** — CloudTrail records the assumed-role session; the `Revision`
  default tag (GITHUB_SHA) ties every mutation to a commit.
- **Information disclosure** — account ids and role ARNs in the Actions logs.
  The repository is public, and so are its workflow logs. A GitHub variable is
  never masked: the runner prints it in the env block of every step that
  receives it, and configure-aws-credentials prints `role-to-assume`, before
  any step can register a mask, so the workflows that read ids from variables
  published every workload account's id. Mitigated: every account id and role
  ARN a workflow reads is a secret on the GitHub Environment its job declares
  (`DEPLOY_ROLE_ARN` and `DEPLOY_ACCOUNT_ID` on `development`, `staging` and
  `production`; `AWS_ROLE_ARN` and `TERRAGRUNT_ACCOUNT_ID` on `plan`;
  `E2E_AWS_ROLE_ARN` on `e2e`), which the runner masks whole from the job's
  first line; and the first step in each job that receives one runs
  `scripts/mask-aws-ids.sh` as its first command, registering every
  twelve-digit window of every digit run and every IAM ARN in it, so the
  derived pieces (the id inside an ARN, the id in the state bucket name a
  terragrunt error prints) are masked before anything prints. A secret
  reaches a step only whole: a value computed from it (`fromJSON`, `format`)
  is not masked and would print in that step's env block before its mask
  ran, so pieces are cut out in shell after the mask. e2e.yml no longer takes
  the account id as a dispatch input, which no step can mask before it is
  printed. Each workflow fails while a name it reads is still a variable at
  any level, and its first job, which declares no environment, refuses the
  name as a repository- or organization-level secret, which every workflow in
  the repository could read and the job would fall back to. Held by
  `scripts/check-workflow-id-masking.py` (which tokenises expressions, so a
  read in another case or index spelling, a whole-context read or a computed
  name is caught; and which recognises an id by its name, by the keys it is
  fed into and, in a job holding AWS credentials, refuses every variable) and
  the mask script's self-test (synthetic ids only) on every pull request.
  Residual: (a) with step debug
  logging on, the runner traces the value it reads for a variable before the
  comparison that guards against it, unmasked, so a debug run while an old
  variable still exists prints it; delete the variables, and never run with
  debug logging while one exists. (b) Only ids in the secrets a job reads are
  masked: an id of another account that an API response carries into a plan
  (an AWS-owned account in a managed ARN, another of your accounts reached
  through a lookup) prints as returned. (c) The mask script runs from the
  checkout, so in ci.yml's plan job it is the pull request's copy; a
  same-repository branch can edit it as freely as it can edit the workflow,
  which is why the `plan` environment's reviewers, not the script, are the
  control on what a pull request does with the plan role. Fork pull requests
  receive no secrets. (d) drift.yml's `DRIFT_PLAN_ROLE_ARNS` is a secret
  on the `drift` environment, and what keeps the staging and production plan
  roles it names off other branches is that environment's main-only
  deployment-branch policy, which no workflow can read: the environment must
  exist, protected, before drift.yml names it (see the drift entry above). (e) e2e.yml's target is whatever account its role
  lives in: the account id is the role ARN's own account segment, so nothing
  independent ties the run to the `account_dir` input, and e2e.sh's
  `sts get-caller-identity` comparison only confirms the credential is the
  role's (it is a real cross-check on a local `task e2e`, where the operator
  states the id). The binding is who may set the `e2e` environment's secret
  and its required reviewers. (f) The gate recognises an id by name and by
  use; a value carrying an id under a name outside the naming rule, read only
  in a job that holds no AWS credentials and fed into no id-named key, is
  caught at review, not by the gate. (g) The `ecr-public-pull` role in
  `workload-development` is consumed by eks-gitops, another public
  repository, whose workflows read its ARN (and so that account's id) from a
  repository variable today. The leaf now documents it as a secret masked
  before use; until eks-gitops makes that change, the development account's
  id is published through that repository's logs.

## 2. Terraform state  (`scripts/init-backend-aws.sh`, S3 backend)

- **Tampering / Information disclosure** — state holds resource metadata and some
  secrets material. Mitigated: S3 buckets are versioned + AES-256 encrypted, keyed
  `{env}/{component}/terraform.tfstate`, with native conditional-write locking
  (`use_lockfile`). Per-component/per-env state = isolated blast radius. The
  highest-value state buckets — `fleet-hub` (every vended cluster's OpenTofu state)
  and `portal-hub` (portal's cross-account state) — go further: SSE-KMS with a
  dedicated CMK, a bucket policy that denies any non-TLS request
  (`aws:SecureTransport=false`), and server access logging to a private sibling
  bucket.
- **Residual** — bucket policy and account-level SCPs are what keep state private;
  a fork should confirm the tfstate bucket is not readable outside the CI role.

## 3. EKS control plane  (`cluster`)

- **Information disclosure / Spoofing of the API server** — a world-open endpoint.
  Mitigated (fail-closed): `endpoint_public_access` defaults **false**; when true,
  variable validation *rejects* an empty `endpoint_public_access_cidrs` — there is
  no `0.0.0.0/0` fallback. Private access is always on. Secrets are envelope-
  encrypted with a KMS CMK (`encryption_config`).
- **Tampering** — cluster admin. Mitigated: `authentication_mode = API`, admin via
  a dynamically-mapped access entry (no hardcoded ARN); extra principals go through
  `access_entries` with real ARNs only.
- **Residual** — addon supply chain: versions are pinned (`eks_addon_versions`)
  so an addon cannot silently roll to an unvetted build.

## 4. Workload identity  (`modules/aws/workload-identity`, tenant `pod-identity.tf`)

- **Spoofing / Elevation** — a pod assuming a role it should not. Mitigated: the
  `workload-identity` module mints **Pod Identity** roles whose trust is
  `pods.eks.amazonaws.com` only (no OIDC/web-identity principal), bound to an exact
  (cluster, namespace, service-account) via an EKS Pod Identity association. A
  `tofu test` gate asserts the trust never gains a web-identity action and that
  inline policies pass through unbroadened. Every workload role in the repo is
  minted this way, one per tenant; web-identity (OIDC) trust is reserved for the
  control-plane roles that assume from outside the cluster — the agent-platform
  operator, fleet-hub, portal-hub, and GitHub Actions CI federation.
  The `workload-identity` module renders an optional per-statement `Condition`, so
  a caller's grant can be ARN-scoped **and** tag/StringEquals-locked. The addon and
  tenant grants use this: the AWS Load Balancer Controller's mutating EC2/ELB verbs
  are gated on the upstream `elbv2.k8s.aws/cluster` resource tag (it can only touch
  resources it created), argo-events' SQS/SNS access is scoped to the account/region
  (not `sqs:*`/`sns:*` on `*`), and each tenant's `kafka-cluster` grant is scoped to
  that tenant's own MSK cluster/topic/group ARNs. Feature-gated grants are omitted
  entirely when disabled rather than falling back to `*`.
- **Residual** — inline policy scope is the tenant author's responsibility; the
  module does not widen it, but it does not audit it either. Keep `Resource`
  scoped or condition-locked (the checkov gate enforces this at CI).

## 5. Cross-account fleet vend  (`fleet-vend`, `cluster` path/boundary vars)

- **Elevation of privilege** — a vended spoke minting roles outside its ceiling.
  Mitigated: the vend role's `iam:CreateRole`/`CreatePolicy` is double-locked — every
  role + the encryption policy must land under `cluster_iam_role_path`
  (`/eks-fleet/*`) **and** carry the vend permissions boundary
  (`iam:PermissionsBoundary` condition). A role that omits either is rejected by AWS
  at create time.
- **Residual** — the boundary policy itself is the ceiling; review its Deny
  statements, not just the Allows (the boundary-ceiling model is why the checkov
  IAM-wildcard skips are safe).

## 6. Org guardrails  (`org-scp`, `org-identity`, `break-glass`)

- **Tampering / Elevation at the org level** — disabling audit logging, leaving the
  org, using unapproved regions. `org-scp` authors the Deny policies that cover
  these and creates them in Organizations, where they bind regardless of
  account-level IAM once attached. Attachment is the operator's act, not this
  repo's: every policy ships with `target_ids = []`, because attaching an SCP is
  org-wide with no undo path for whoever it locks out, and the OU ids it would
  name are estate values a substrate repo does not hold. **Until an operator
  supplies `target_ids`, these threats are unmitigated** — the policies exist and
  govern nothing. Supply the OU ids in
  `live/aws/management/<region>/org/org-scp/terragrunt.hcl` to close them.
- **Repudiation of emergency access** — Mitigated: `break-glass` roles fire an SNS
  alert on assumption and cap `max_session_duration` (default 1h). Identity Center
  (`org-identity`) provides least-privilege permission sets rather than shared
  admin.

## 7. Denial of service

- **Cluster** — system nodes hitting DiskPressure mid-converge (a real past
  incident). Mitigated: `system_node_disk_size` sizes the Bottlerocket data volume
  explicitly with a `>= 50` validation, and Cilium's WireGuard/health ports are
  opened on the node SG.
- **State** — concurrent applies corrupting state. Mitigated by the S3 lockfile.
- **Residual** — this is a single-region template by design (documented in
  `.checkov.yaml`); regional outage is an accepted trade-off a regulated fork must
  revisit.

## What this model excludes

- In-cluster runtime posture (PSS/best-practice admission, image signing) — owned
  by the eks-gitops Kyverno policies.
- AI-platform budget/model guardrails — owned by the eks-agent-platform operator
  (see that repo's runbooks).
- Application-layer threats inside tenant workloads.
