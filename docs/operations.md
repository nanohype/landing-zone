# Operations

Day-to-day procedures for operating the landing-zone infrastructure.

## Planning and Applying

### Single Component

```bash
task plan ACCOUNT=workload-development REGION=us-east-1 ENVIRONMENT=development COMPONENT=network
task apply ACCOUNT=workload-development REGION=us-east-1 ENVIRONMENT=development COMPONENT=network
```

### All Components in an Environment

```bash
task plan ACCOUNT=workload-development REGION=us-east-1 ENVIRONMENT=development
task apply ACCOUNT=workload-development REGION=us-east-1 ENVIRONMENT=development
```

Terragrunt resolves the dependency graph and runs components in the correct order.

### Organization Components

```bash
task plan ACCOUNT=management REGION=us-east-1 ENVIRONMENT=org COMPONENT=org-identity
task apply ACCOUNT=management REGION=us-east-1 ENVIRONMENT=org COMPONENT=org-identity
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

It is also applied **locally**, with the account's own admin credentials, never by `deploy.yml`. In
`workload-development` the deploy role carries `AdministratorAccess` under the `github-actions-boundary`
permissions boundary the component creates, on both the deploy and the plan role, and that boundary
refuses the session's direct writes to the boundary itself, to the roles a `github-oidc` leaf creates
(and their `Component` tag) and to the GitHub OIDC provider (plus stripping any boundary, assuming a
role, minting IAM users or keys, Organizations and account writes, and disabling the audit services;
the list, its reasons and what it does not stop are in
[first-deploy-aws.md](first-deploy-aws.md#execution-model-local-default-vs-ci)). A `deploy.yml` run
with `component=all` reaches the `github-oidc` and `ecr-public-pull` leaves too. Applied, the only
change it plans there is the per-commit `Revision` default tag (`live/root.hcl`), which the boundary
leaves writable, so the run goes through; any other pending change fails there with `AccessDenied`,
and goes in with:

```bash
TERRAGRUNT_ACCOUNT_ID=<workload-development account id> AWS_PROFILE=<its admin profile> \
  task apply ACCOUNT=workload-development REGION=us-east-1 ENVIRONMENT=development COMPONENT=github-oidc
```

The cross-account **network-owner** components (`shared-network`, `egress-network`) and the
**portal** control plane (`portal-*`) deploy from their own `live/aws/network/` and
`live/aws/fleet/` trees, not the per-environment workload accounts.

`fleet-hub` is the exception and it is deliberate: a dedicated hub account needs its own
cluster, network and bootstrap, which a single-account platform does not have yet — so
`live/aws/` carries a fleet-hub leaf in each workload account as well as in the fleet tree,
each against the cluster that environment already runs. Only one of them can apply at a
time: `state_bucket_name` is a globally-unique S3 name with no account element, so the
second collides at apply. Each leaf says so.

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
| **account-local-deps** | Runs `scripts/check-account-local-deps.py` -- a leaf under `live/aws/workload-*/` may not depend on a unit outside its own account directory. A terragrunt `dependency` resolves at config-parse time, so a cross-account one fails `init`, not just `apply`, and no `TF_VAR` bypasses it. CI cannot otherwise see this: `evaluate` resolves against mocks by design and `plan` green-skips without credentials. |
| **architecture-components** | Runs `scripts/check-architecture-components.sh` -- the architecture doc's component inventory must be the components that exist, both directions; CLAUDE.md's layer list is checked in the omission direction only. A documented component that is gone sends a reader to a missing directory; a component no table names is quieter and worse, because the doc reads as complete. |
| **teardown-gates** | Runs `scripts/check-teardown-gates.py` -- in a component declaring `force_destroy_buckets`, every teardown-gate attribute must resolve permissively when the lever is set, and every protectable resource must carry one, and a gate attribute may sit only on a kind the script classifies as protectable. A module without the lever declares why in the script's EXEMPT table, and names in GATELESS_HELD the kinds it holds that carry no gate, so a kind dropped from the script's table is reported while the tree still holds it. `--self-test` builds a module per protectable kind and requires each gate to be reported when pinned closed and when left off. No tflint or checkov rule covers `force_destroy` or `deletion_protection`, and a `tofu test` assert cannot reach a grandchild module's attributes. |
| **tenant-schema-readers** | Runs `scripts/check-tenant-schema-readers.py` -- every field a `tenants` object type declares must be read by a resource in that component. A field with no reader is a control an operator can set, sees accepted, and believes is in force. |
| **workflow-id-masking** | Runs `scripts/check-workflow-id-masking.py`, and the self-tests of both it and `scripts/mask-aws-ids.sh` -- every AWS account id and role ARN a workflow reads is a secret on the environment its job declares, never a variable, and reaches a step only whole; the first step that receives one runs the mask script as its first command, unconditionally; none reaches a workflow- or job-level env, `run:` text or an action input ahead of the mask; and each workflow refuses a name it reads as a secret while it is a variable at any level, or a secret at repository or organization level. See [Account ids in the Actions logs](#account-ids-in-the-actions-logs). |
| **plan** | PRs only. Matrix auto-discovered from `live/aws/workload-development/` and nothing else: the job assumes one credential, the development account's read-only plan role, with one `TERRAGRUNT_ACCOUNT_ID`, so a leaf in any other account would plan against the development account. Staging and production are planned by `drift.yml` with each account's own plan role; `reference-adopt` is render-only and covered by **evaluate**. Runs `terragrunt run --non-interactive -- plan -input=false -lock=false -no-color`, with `TF_INPUT=false` in the step's environment, to show what would change (credential-gated -- skips green unless both the `AWS_ROLE_ARN` and `TERRAGRUNT_ACCOUNT_ID` secrets are set on the `plan` environment, and fails, through `refuse-inherited-config` and its own first step, while either name is still a variable or is a repository or organization secret). The credential is the read-only plan role, which cannot write the `.tflock` object `root.hcl`'s `use_lockfile = true` takes, so the plan skips the lock. The PR plan writes nothing and nothing applies its result (it gates on whether the plan runs, not on what it would change), so it never contends with an apply. Like `deploy.yml`'s and `drift.yml`'s, it runs non-interactively: a unit missing a required variable fails the plan at once instead of holding the job at tofu's input prompt. |

### Account ids in the Actions logs

The repository is public, and so are its Actions logs. Every AWS account id and IAM role ARN a workflow reads is a **secret on the GitHub Environment its job declares**, never a variable.

| Secret | Environment | Workflow |
|---|---|---|
| `DEPLOY_ROLE_ARN`, `DEPLOY_ACCOUNT_ID` | `development`, `staging`, `production` | deploy.yml, destroy.yml (`production`: deploy.yml only) |
| `AWS_ROLE_ARN`, `TERRAGRUNT_ACCOUNT_ID` | `plan` | ci.yml's plan job |
| `E2E_AWS_ROLE_ARN` | `e2e` | e2e.yml |
| `DRIFT_PLAN_ROLE_ARNS` | `drift` (main-only deployment-branch policy, no reviewers) | drift.yml |

A variable cannot be rescued by masking: the runner prints it in the env block of every step that receives it, and configure-aws-credentials prints it as `role-to-assume`, before any step can register a mask. A secret is masked from the job's first line, but only whole: the account id inside a role ARN, the state bucket `<account_id>-<region>-tfstate` in a terragrunt error, an ARN in an AWS AccessDenied message, or a value an expression computes from the secret (`fromJSON(...)`, `format(...)`) would print in the clear. So a secret reaches a step only whole, as `${{ secrets.NAME }}`, and in each job the first step that receives one runs `scripts/mask-aws-ids.sh` as its first command, unconditionally. It registers every twelve-digit window of every run of twelve or more digits, and every IAM ARN, with `::add-mask::`, before anything else prints (only its JSON-decoding pass needs `jq`, and that pass runs after the raw masks); refuses a value spanning several lines (the runner would mask each line on its own); and never prints a value, not even in an error. Masks are per job, so every job that reads one masks it. From that line on, the job's log shows `***` for each id and ARN: the credentials step's inputs, every later env block, `sts get-caller-identity`, and terragrunt's output. A piece the job needs (e2e.yml's account id) is cut out in shell after the mask and handed on as a step output. Later steps read the secret from the `secrets` context again rather than through a job output, because the runner drops a job output that carries a masked value.

The `secrets` context falls back from the environment to the repository and the organization, so deploy.yml, destroy.yml, ci.yml, e2e.yml and drift.yml each begin with a `refuse-inherited-config` job that declares no environment and costs no approval. It fails the run when a name the workflow reads is set at repository or organization level, as a **secret** (every workflow in the repository could read it, and the job would fall back to it if the environment lost its own; the likeliest slip is a `gh secret set` without `--env`) or as a **variable**. The job that reads the secret also compares the variable against `''` in its first step, which sees the environment's, the repository's and the organization's values, so a variable left on the environment itself fails too. Only `true` or `false` reaches a step, so a normal run prints none of these values even while one is misplaced. A pull request from a fork receives no secrets, so its comparisons are `false` and it passes.

An **organization-level** value counts: the expression cannot tell the levels apart, and a value this repository can read is one edit from printed. A generic name held at organization level for other repositories (`AWS_ROLE_ARN`, `TERRAGRUNT_ACCOUNT_ID`) therefore turns this repository's runs red. The fix is to narrow that organization secret's or variable's repository access so it no longer includes this repository; delete it (`gh secret delete NAME --org <org>`, `gh variable delete NAME --org <org>`) only if nothing else uses it. Each error message names both.

The residual: with step debug logging on (a re-run with debug logging, or `ACTIONS_STEP_DEBUG`), the runner traces how it evaluates each expression, including the value it reads for a variable, before the comparison. A secret is masked there; a variable is not. The `GITHUB_TOKEN` cannot read repository variables, so no other check exists: delete the old variables, and never run a workflow with debug logging while one exists.

`scripts/check-workflow-id-masking.py` (CI job `workflow-id-masking`) holds all of this in the workflow text. It tokenises every expression rather than matching one spelling, so a read is a read whatever its case (`Vars.X`) or form (`vars['X']`); a whole `secrets`, `vars` or `inputs` context (`toJSON(secrets)`) or a computed index is refused wherever it appears. It requires: no id from `vars.`, and no variable at all in a job that can hold AWS credentials except in the comparison form; no id as a dispatch input; an id secret only as the whole value of a step env entry or input; the mask step first, with no `if:`, no `continue-on-error` and a bash shell, and no later receiving step that runs after a failure; no workflow- or job-level env; a key named like an id (`TERRAGRUNT_ACCOUNT_ID`, `ACCOUNT_ID`) and `role-to-assume` fed only from a whole secret or a mask step's output; `mask-aws-account-id: true` on every configure-aws-credentials step; the `refuse-inherited-config` comparison and the leftover-variable comparison for every secret read; and no literal account id other than the tree's placeholders, an unquoted one included (YAML reads `OWNER: 222233334444` as a number, and the runner prints it as text), read as the text it was written as so that one YAML takes for octal (`012345670123`) is still seen. Action input names are compared case-insensitively, as the runner reads them, so `Role-To-Assume` is held to the `role-to-assume` rule and `Mask-AWS-Account-Id: true` satisfies the masking one. A finding is printed as an `::error` annotation, which outlives the diff, so no finding repeats an id: any run of twelve or more digits other than a placeholder, in quoted workflow text or a YAML parse error, prints as `<account id>`; quoted text is redacted before it is cut to length, and a parse error is reported as the parser's problem, line and column without the excerpt PyYAML has already cut, so no head or tail of an id survives either. `scripts/check-drift-workflow.py`, which runs beside it, prints through the same redaction. Both self-tests fail a mutation whose findings carry an id, or the head or tail of one it planted. The id-masking gate's self-test also fails a mutation rejected by any rule but the one it plants, requires the floor to refuse each shortfall on its own and the gate to refuse a tree git does not track as this repository, and checks that its own checks report a case that would pass vacuously. Ids are recognised by name and by where they go, which makes the name a rule: a secret, variable or input that carries an account id, a role ARN or the state bucket is named with `ROLE_ARN`, `ARN`, `ACCOUNT_ID`, `ACCOUNT_NUMBER`, `AWS_ACCOUNT`, `STATE_BUCKET` or `TFSTATE` among its words.

**What remains visible.** Account directory names (`workload-staging`), environment and region names, role names that appear outside an ARN, and the ids of accounts whose ids are in none of the secrets a job reads: an AWS-owned account in a managed resource's ARN, or another of your accounts that a plan reaches through an API response rather than through the job's own secrets. The repository holds only placeholder ids, so the last case needs an API to return one.

**Migrating from variables.** Set each secret on its environment, then delete the variable it replaces. Until both are done for a workflow, its run fails with an error naming what is left. With the `gh` CLI, for each `<env>` in `development`, `staging` and `production`, read each value from the account's `github-oidc` outputs and paste it when `gh secret set` prompts (or pipe it in): without `--body`, the value comes from stdin and stays out of the command line and shell history.

```bash
REPO=nanohype/landing-zone

# deploy.yml and destroy.yml, once per environment
gh secret set DEPLOY_ROLE_ARN   --env <env> --repo "$REPO"   # the workload-<env> deploy role ARN
gh secret set DEPLOY_ACCOUNT_ID --env <env> --repo "$REPO"   # the workload-<env> account id
gh variable delete DEPLOY_ROLE_ARN   --env <env> --repo "$REPO"
gh variable delete DEPLOY_ACCOUNT_ID --env <env> --repo "$REPO"

# ci.yml's plan job: the development account's plan role and id
gh secret set AWS_ROLE_ARN          --env plan --repo "$REPO"   # the plan role ARN
gh secret set TERRAGRUNT_ACCOUNT_ID --env plan --repo "$REPO"   # the development account id
gh variable delete AWS_ROLE_ARN          --repo "$REPO"
gh variable delete TERRAGRUNT_ACCOUNT_ID --repo "$REPO"

# e2e.yml
gh secret set E2E_AWS_ROLE_ARN --env e2e --repo "$REPO"   # the target account's deploy role ARN
gh variable delete E2E_AWS_ROLE_ARN --repo "$REPO"   # or --env e2e, wherever it was set
```

`gh variable list --repo "$REPO"`, `gh variable list --env <env> --repo "$REPO"` and `gh secret list --repo "$REPO"` show what is left; a `gh variable delete` for a name that does not exist at that level fails harmlessly. A name held at organization level is handled as above. ci.yml's plan job reads both its secrets or skips: an unconfigured fork or repository stays green, while a leftover variable, or either name stored as a repository secret, turns every pull request red until it is moved.

### deploy.yml -- Manual Deploy

**Trigger:** Workflow dispatch (manual).

**Inputs:**
- `account` -- target account directory; must be `workload-<environment>` (see Configuration below)
- `region` -- target region
- `environment` -- development, staging, or production (the `environment` input is a fixed choice)
- `component` -- specific component name or "all"
- `action` -- plan or apply

Uses GitHub environment protection rules -- production requires approval, before the job starts. Both paths run non-interactively and hand tofu the same flags. When `component=all`, runs `terragrunt run --all --non-interactive -- <action>`, and terragrunt appends `-input=false` to the plan or apply and `-auto-approve` to an apply on its own. Otherwise it runs in the specific component directory, where terragrunt passes the tofu command through as written, so the workflow spells the same flags out: `terragrunt run --non-interactive -- plan -input=false`, or `terragrunt run --non-interactive -- apply -input=false -auto-approve` for an apply. On either path a unit missing a required variable fails at once instead of stopping at tofu's input prompt, and an apply proceeds without a confirmation prompt: the environment approval is the confirmation, and with no one at the keyboard tofu's own prompt would otherwise fail the job or hold it until the timeout without applying. A plan is never auto-approved: it has nothing to confirm. Terragrunt's automatic `tofu init` takes no flag from either command line, so the step also sets `TF_INPUT=false`, which tofu reads as `-input=false` on every command, init included: a backend or variable needing a value fails init at once instead of waiting at a prompt.

The `environment` choice covers only the three workload environments. The management-account `org` components (the [Organization Components](#organization-components) above) are **local-CLI-only** — deploy them with `task apply ACCOUNT=management ENVIRONMENT=org COMPONENT=<component>` under your own admin/SSO credentials. `org` is intentionally not a workflow choice because the management account is applied rarely and by hand.

**Configuration:** two secrets on each GitHub Environment (Settings > Environments > `<environment>` > Environment secrets), and on nothing broader. The job declares `environment: <environment>`, so each environment carries its own account's values:

| Secret | Value |
|---|---|
| `DEPLOY_ROLE_ARN` | the OIDC deploy role in the `workload-<environment>` account (the `github-oidc` component's `deploy_role_arn` output in that account) |
| `DEPLOY_ACCOUNT_ID` | the 12-digit id of the `workload-<environment>` account. The job passes it to terragrunt as `TERRAGRUNT_ACCOUNT_ID`, and `root.hcl` names the state bucket `<account_id>-<region>-tfstate` from it; without it the bucket would be named after the tracked `account.hcl` placeholder |

A GitHub secret that an environment does not set resolves to the repository's value, then the organization's. That is why these are not `AWS_ROLE_ARN` and `TERRAGRUNT_ACCOUNT_ID`, the read-only plan role and account id `ci.yml`'s plan job reads from the `plan` environment: a name shared with the plan role invites setting it once at repository level, and an environment that forgot its own would silently inherit it. For the same reason a first job, which declares no environment and so sees only repository and organization values, fails the run when either `DEPLOY_*` name is set at one of those levels as a secret or as a variable, and the deploy job fails when either is still a variable on the environment. Never set them there.

Before any credential is issued, the job fails when the environment sets neither or only one of the two, when `DEPLOY_ACCOUNT_ID` is not 12 digits, when `DEPLOY_ROLE_ARN` is not a role ARN in `DEPLOY_ACCOUNT_ID`'s account, when the `account` input is not `workload-<environment>`, when the `region` input names no directory under that account, or when the `component` input is neither `all` nor a single directory name holding a `terragrunt.hcl` under that environment. After assuming the role it compares the credential's account (`aws sts get-caller-identity`) with `DEPLOY_ACCOUNT_ID` and fails on a mismatch, so a role and an id for two different accounts never reach terragrunt.

The account id and the role ARN do not appear in the run log: the first step masks both, and every derived piece, before anything prints (see [Account ids in the Actions logs](#account-ids-in-the-actions-logs)). The error messages name neither either way.

One environment names one account, so the workflow deploys only `live/aws/workload-<environment>/` leaves. The `backup/` and `network/` account directories also hold `development`/`staging`/`production` leaves; run with the workload account's role and id, they would build that account's stack inside the workload account. Deploy them locally under that account's own credentials, the same way as the `org` components: `task apply ACCOUNT=<account> REGION=us-east-1 ENVIRONMENT=<environment> COMPONENT=<component>` with `TERRAGRUNT_ACCOUNT_ID` exported as that account's id.

### destroy.yml -- Manual Destroy

**Trigger:** Workflow dispatch (manual).

**Inputs:**
- `account` -- must be `workload-<environment>` (see Configuration below)
- `region` -- target region
- `environment` -- development or staging only (production excluded)
- `component` -- specific component name or "all"
- `confirm` -- must exactly match the environment name

The confirmation guard (`confirm == environment`) prevents accidental destroys. Runs `terragrunt run --non-interactive -- destroy -input=false -auto-approve` in the component directory, or `terragrunt run --all --non-interactive -- destroy -input=false` for `all`: `run --all` appends `-auto-approve` to a destroy on its own but, unlike for plan and apply, not `-input=false`, so both paths spell that flag out and hand tofu the same flags. On either path a unit missing a required variable fails at once instead of stopping at tofu's input prompt, and the destroy proceeds without a confirmation prompt. The step also sets `TF_INPUT=false`, which tofu reads as `-input=false` on every command, so terragrunt's automatic `tofu init`, which takes no flag from the command line, fails at once on anything it would ask for too. The `confirm` input and the environment's protection rules are the confirmation; tofu's own prompt has no one to answer it in a workflow run.

In `development`, a `component=all` destroy is expected to **fail at the `github-oidc` and `ecr-public-pull` leaves**, after destroying every other unit (neither has a dependent). Their first destroy step detaches a policy from a role the deploy role's permissions boundary protects (`DetachRolePolicy` on the deploy and plan roles, `DeleteRolePolicy` on the ECR Public pull role), so the call is refused and nothing in those two leaves is removed. That is the boundary doing its job: without it the run would delete the CI role it is running as. Those leaves are removed only by a local destroy with the account's own admin credentials (`task destroy` with the same `TERRAGRUNT_ACCOUNT_ID`/`AWS_PROFILE` as the local apply in [Deployment order](#deployment-order)), destroying `ecr-public-pull` before `github-oidc`.

**Configuration:** the same environment-only `DEPLOY_ROLE_ARN` and `DEPLOY_ACCOUNT_ID` secrets as `deploy.yml`, on the `development` and `staging` GitHub Environments, with the same checks and the same masking: neither set at repository or organization level, neither left as a variable anywhere, both set on the environment and naming one account, the `account` input equal to `workload-<environment>`, the `component` input `all` or a leaf directory under it, and the assumed credential's account equal to `DEPLOY_ACCOUNT_ID`. The last matters most here: a destroy run with the state of one account and the credential of another sends the state's resource ids to the wrong account, where most of them are simply not found and dropped from state, leaving the real resources running untracked.

### drift.yml -- Drift Detection

**Trigger:** Cron schedule, 6 AM UTC Monday-Friday. Also supports manual dispatch.

**Scope:** every `production` and `staging` live leaf whose account has a plan role, matrix auto-discovered from the tree with `git ls-files` (mirroring `ci.yml`) -- a new production/staging component starts being watched with no workflow edit once its account directory is in the `DRIFT_PLAN_ROLE_ARNS` secret. Development is ephemeral and the `org`/`hub` control planes are covered by their own bring-up, so both are excluded.

**Behavior:** Runs `terragrunt run --non-interactive -- plan -input=false -lock=false -detailed-exitcode` for each discovered leaf, non-interactively like `deploy.yml` and `destroy.yml`, so a leaf missing a required variable is reported as a plan error rather than holding the job at tofu's input prompt. The step also sets `TF_INPUT=false`, which tofu reads as `-input=false` on every command, so terragrunt's automatic `tofu init` fails the same way on anything it would ask for. Exit code 2 means changes detected (drift). When drift is found, creates or updates a GitHub issue labelled `drift` with the plan output. `select-accounts` and `detect-drift` run in the `drift` GitHub Environment, which admits `main` only: its OIDC subject, `repo:nanohype/landing-zone:environment:drift`, is the one a staging or production plan role trusts, and its secret holds the role map. A dispatch from any other branch stops at `select-accounts`. The environment carries no required reviewers, which would hold every scheduled run for an approval.

- **A plan that cannot run is an error, not "no drift".** Exit code 1 opens or updates an issue labelled `drift-error` and fails the job. A plan role the job cannot assume takes the same path: the `Configure AWS credentials` step continues on error, and the plan step records exit code 1 with a message naming the account directory (never the role ARN), so the account's leaves each get a `drift-error` issue and the run ends red. Issue titles name the account directory and the leaf (`Drift detected: <account>/<env>/<component>`, `Drift check error: <account>/<env>/<component>`), as do the job names, because the same `<env>/<component>` can exist in several accounts; an open issue with the same title is commented on rather than duplicated, and the lookup pages through every open issue with the label. The usual causes are the account's `github-oidc` leaf not applied yet, a trust that does not admit the job's OIDC subject (`environment:drift`), or a `DRIFT_PLAN_ROLE_ARNS` entry naming the wrong role; the AWS error itself is in that step's log.
- **No lock.** `root.hcl` sets `use_lockfile = true`, and a plan that locks writes a `.tflock` object beside the state. The plan role is read-only and cannot write it, so the drift plan runs with `-lock=false`. That is safe because the plan writes nothing and nothing applies its result: it reads state, and its output is a report rather than a saved plan, so it never contends with an apply. An apply at the same moment can only make one report stale, and the next run corrects it.
- **Account ids are masked in the logs.** The repository is public, and every value in `DRIFT_PLAN_ROLE_ARNS` carries a real account id. The map is a secret, so the runner prints it as `***` wherever it appears whole, including the env block of each step that receives it. A secret is masked as a whole, not by its parts, so every job that reads it runs `scripts/mask-aws-ids.sh`, the mask script every workflow uses, naming `DRIFT_PLAN_ROLE_ARNS`, as the first command of the first step that receives it: that registers every twelve-digit window of every digit run and every IAM ARN in the map, in its raw text and in its JSON-decoded keys and strings, with `::add-mask::` before anything else in the job prints. Masks hold for the rest of the job, so the role step's own output, the `role-to-assume` input the credential step prints, every later step's env block and the raw plan output (which names the state bucket and role ARNs) all show `***` in place of an id or ARN. What stays visible: account directory names, regions, environments and components (in job names, the matrix and the summary), and an account id that is not in the secret at all, such as a cross-account reference in plan output. No job output carries a role value: the runner drops a job output that contains a masked value, so `select-accounts` hands on account directory names only and each `Drift Check` job reads its own role from the secret. This was checked against a local model of the runner's masker (step order, env blocks printed before a step runs, `::add-mask::` taking effect from the next line, masked job outputs dropped) while drift.yml ran its own drift-specific mask script, not in a live run, and that model has not been re-run since drift.yml moved onto `scripts/mask-aws-ids.sh`, which masks a superset of what the retired script did. Two things keep it true as the files change, both in ci.yml's `workflow-id-masking` job on every pull request: the self-test of `scripts/mask-aws-ids.sh` (synthetic ids only, `--self-test`, including role-map cases), and `scripts/check-workflow-id-masking.py`, which fails a pull request in which any drift.yml job reads the secret in a step before the one that runs the mask script, or prints anything ahead of it, exactly as it does for every other workflow. Two limits: with step debug logging on, the runner traces each expression it evaluates, which would print the value of a `DRIFT_PLAN_ROLE_ARNS` *variable* left at repository or organization level (in `refuse-inherited-config`) or on the `drift` environment (in `select-accounts`); a secret is masked there (see below); and only ids in the secret are masked (see above). The other workflows hold their ids the same way; see [Account ids in the Actions logs](#account-ids-in-the-actions-logs).
- **Account ids are redacted from the issues.** The runner's masking rewrites what it prints, not what a step writes to a file or sends to the API, so an issue would carry the ids in the clear. Before any step reads the plan output for an issue, `scripts/redact-account-ids.py` replaces every id in `DRIFT_PLAN_ROLE_ARNS` (fixed-string, wherever it appears) and every other standalone run of twelve digits with `<account-id>`; the issue step runs the same two rules over the title and the whole body. Both receive the secret through the environment, never through the script text. The redactor runs its self-test first and then requires the secret to hold an id (`--require-ids`), and the issue step refuses a secret with no id too, so a redaction that cannot run fails the job without filing anything; the same self-test runs on every pull request in ci.yml's `workflows` job. The run summary and the job's annotations name account directories and leaves, never role values, and every name printed there replaces any run of twelve or more digits.

**Configuration:** one secret, `DRIFT_PLAN_ROLE_ARNS`, on the `drift` GitHub Environment and nowhere else: a single-line JSON object mapping each account directory under `live/aws/` to the read-only plan role `github-oidc` creates in that account (its `plan_role_arn` output). Shown here expanded for reading, with synthetic ids:

```json
{
  "workload-staging": "arn:aws:iam::222222222222:role/github-actions-plan",
  "workload-production": "arn:aws:iam::333333333333:role/github-actions-plan",
  "network": "arn:aws:iam::444444444444:role/github-actions-plan",
  "backup": "arn:aws:iam::666666666666:role/github-actions-plan"
}
```

Store it as one line. The runner masks each line of a multi-line secret on its own, so a pretty-printed map would register `{` and `}` as secrets, and `select-accounts` refuses one. Set it from a local file that is never committed, compacted with `jq`, so the value never appears on a command line or in shell history:

```bash
jq -c . drift-plan-role-arns.json | gh secret set DRIFT_PLAN_ROLE_ARNS --env drift --repo nanohype/landing-zone
```

(`gh secret set DRIFT_PLAN_ROLE_ARNS --env drift --repo nanohype/landing-zone` with no input prompts for the value instead.) The production and staging leaves live in several account directories, and `root.hcl` assumes no role: the backend and the provider both act as the job's credential, so a leaf can only be planned with a credential in its own account. Each leaf assumes its account's plan role and takes its account id from that role's ARN, passing it to terragrunt as `TERRAGRUNT_ACCOUNT_ID` so `root.hcl` names the state bucket `<account_id>-<region>-tfstate`. The credential and the bucket come from one value, so they cannot name different accounts. In an estate where several account directories are one AWS account, map each of them to that account's plan role.

- An account directory with no entry is skipped: its leaves are not planned, the run summary names each of them, and a notice names the account. Drift detection can be armed one account at a time, as each account gets its `github-oidc` plan role.
- An entry whose value is not an IAM role ARN, or whose key names no account directory holding a production or staging leaf (a misspelt key, or an account whose last such leaf was removed), is reported as an error and left out. The accounts mapped correctly are still planned, and the `report-config-errors` job then fails the run. When an account directory's last production or staging leaf is removed, remove its key too.
- The run fails before any leaf is planned when the secret is unset, spans several lines, is not a JSON object, or maps no account directory to a valid plan role. A scheduled run that checked no account does not report "no drift".

**The secret is environment-only.** `refuse-inherited-config` declares no environment, so it sees only repository and organization values, and fails the run if `DRIFT_PLAN_ROLE_ARNS` exists there as a secret or as a variable. A repository or organization secret is readable by every workflow in the repository, not only by jobs the `drift` environment's branch policy admits, and it is what the drift jobs would read if the environment lost its own. A variable is not masked, so any job printing it would publish the ids; it is also where this map used to live, so delete it when moving to the secret:

```bash
gh variable delete DRIFT_PLAN_ROLE_ARNS --repo nanohype/landing-zone
```

A variable of that name on the `drift` environment itself is visible only to a job declaring that environment, so `select-accounts` compares it too, in the step that masks the secret, and fails the run on one (`gh variable delete DRIFT_PLAN_ROLE_ARNS --env drift --repo nanohype/landing-zone`). `detect-drift` declares the same environment and needs `select-accounts`, so one check covers both.

Each of those steps passes only whether a value is set (`true` or `false`), never the value, so in a normal run it prints none even when one exists. With step debug logging on (re-running with debug logging, or `ACTIONS_STEP_DEBUG`), the runner traces how it evaluates each expression, intermediate values included: a secret prints as `***` there, but a variable does not, so a debug run while a `DRIFT_PLAN_ROLE_ARNS` variable still exists, at repository level or on the `drift` environment, would publish every account id in it. The workflow's token cannot read variables, so nothing can check for one without evaluating it. Delete the old variable before this change merges, and never run drift.yml with debug logging while one exists.

**What a skipped account looks like.** The run summary's "Drift accounts" section lists the planned account directories, then:

```text
Skipped, because DRIFT_PLAN_ROLE_ARNS has no valid plan role for the account. These leaves were not checked for drift:

- `network`: `production/shared-dns`, `production/shared-network`, `staging/shared-dns`, `staging/shared-network`
```

and the run carries one notice per skipped account ("Drift not checked for network"). A skipped account does not fail the run, and its leaves get no `Drift Check` job at all, so no issue can be filed for them: an account missing from the secret is unwatched, and the summary is the only place that says so.

#### Arming drift detection: one plan role per account

Each account directory holding a `staging` or `production` leaf needs a read-only plan role of its own, because `root.hcl` assumes no role and a leaf can only be planned with a credential in its own account. Today only `workload-development` has a `github-oidc` leaf, so no account below has a plan role yet, and drift.yml fails at `select-accounts` until at least one entry exists.

**First:** complete the [required setup](#required-before-any-staging-or-production-plan-role) below. Its `drift` environment is what these plan roles trust, and its `DRIFT_PLAN_ROLE_ARNS` secret is where step 4 records them.

The account directories that hold `staging` or `production` leaves today (from `live/aws/`; `reference-adopt` is never applied, and the other directories hold no `staging` or `production` leaf):

| Account directory | Its `staging`/`production` leaves | Put the `github-oidc` leaf under | Deploy role in that leaf | Plan role in that leaf |
|---|---|---|---|---|
| `workload-staging` | every workload component, `staging` | `staging` | `allowed_subject_claims = ["environment:staging"]` (deploy.yml/destroy.yml) | `plan_allowed_subject_claims = ["environment:drift"]` |
| `workload-production` | every workload component, `production` | `production` | `allowed_subject_claims = ["environment:production"]` (deploy.yml) | `plan_allowed_subject_claims = ["environment:drift"]` |
| `network` | `shared-network`, `shared-dns` in both | `production` | `create_deploy_role = false`: no workflow deploys into this account | `plan_allowed_subject_claims = ["environment:drift"]` |
| `backup` | `shared-backup` in both | `production` | `create_deploy_role = false`: no workflow deploys into this account | `plan_allowed_subject_claims = ["environment:drift"]` |

The OIDC provider and both roles are account-global, so each account gets exactly **one** `github-oidc` leaf; the table names the conventional directory for it. The trust rules follow the **account**, not that directory: `live/_envcommon/aws/github-oidc.hcl` reads every `env.hcl` under the account directory and passes the set as `account_environments`, and the component holds a plan role in any account that holds `staging` or `production` to the rules below even when its leaf sits under `development` (as it would in `network` or `backup`, which hold development directories too). For each account directory above:

0. **Create the account's state backend.** None of these accounts has one yet, and the local apply in step 3 cannot initialise without the `<account_id>-us-east-1-tfstate` bucket. Under that account's credentials, run `task init-backend REGION=us-east-1` (it takes the caller's account id, or `ACCOUNT_ID=<id>`), which runs `scripts/init-backend-aws.sh`.
1. **Add the leaf** at `live/aws/<account>/us-east-1/<env>/github-oidc/terragrunt.hcl`, modelled on the `workload-development` one, with `github_repos = ["landing-zone"]`, the deploy-role setting from the table, and the plan role left on (`create_plan_role` defaults to true) with `plan_allowed_subject_claims = ["environment:drift"]`. Do not copy its `managed_policy_arns`: a staging or production deploy role is granted on its own decision, and `AdministratorAccess` is refused there too unless `create_permissions_boundary` (or `permissions_boundary_arn`) is set. The component refuses anything else in these accounts, whichever environment directory the leaf sits in: the default `["environment:plan"]` is the development trust, and a second repository in `github_repos` would trust that repository's `drift` environment too, which has no branch policy; both fail the plan rather than ship.
2. **Create or reference the OIDC provider.** AWS allows one provider per issuer per account. If the account has none for `token.actions.githubusercontent.com` (check with `aws iam list-open-id-connect-providers` under that account's credentials), leave `create_oidc_provider` at its default `true`; if it already has one, set `create_oidc_provider = false` and the component references it.
3. **Apply it locally with that account's credentials**, the same way as the `org` components: `TERRAGRUNT_ACCOUNT_ID=<that account's id> AWS_PROFILE=<that account's profile> task apply ACCOUNT=<account> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=github-oidc`. Neither deploy.yml nor drift.yml can apply it: the role it creates is the one they would need.
4. **Record the plan role, once the account's leaves are applied.** Read it with `terragrunt output -raw plan_role_arn` in the leaf directory, and add it to the `DRIFT_PLAN_ROLE_ARNS` secret on the `drift` environment under the account directory's name (edit the local JSON file and re-run the `gh secret set` command above; a secret cannot be read back) only after that account's `staging` and `production` leaves have been applied. An entry arms every one of the account's leaves at once: a leaf never applied plans as all creates and files a `Drift detected` issue (about twenty for a workload account), and one whose dependencies have no state yet fails and files a `drift-error` issue. The next run after the entry is added plans that account's leaves; until then they are listed as skipped.

The leaf itself is a `staging` or `production` leaf, so once it exists drift.yml plans it too, with the plan role it created.

#### Required before any staging or production plan role

A plan role in an account that holds `staging` or `production` reads that account's state and data, so it must be reachable from `main` only. Three things make that so, and all three must be in place before the first such leaf is created.

1. **The `drift` GitHub Environment, admitting `main` only, with no required reviewers.** This is a repository setting, and it must exist **before** the change that makes drift.yml declare `environment: drift` merges: a workflow that names a missing environment creates it on its first run, with no deployment-branch policy, and from then until someone protects it any branch could run a job in it and present `environment:drift`. Create it, then restrict it to the `main` branch:

   ```bash
   gh api -X PUT repos/nanohype/landing-zone/environments/drift \
     -F 'deployment_branch_policy[protected_branches]=false' \
     -F 'deployment_branch_policy[custom_branch_policies]=true'
   gh api -X POST repos/nanohype/landing-zone/environments/drift/deployment-branch-policies \
     -f name=main -f type=branch
   ```

   Check it with `gh api repos/nanohype/landing-zone/environments/drift` (expect `custom_branch_policies: true` and no `required_reviewers` rule) and `gh api repos/nanohype/landing-zone/environments/drift/deployment-branch-policies` (expect one policy, `main`). No reviewers: the scheduled run would wait for an approval every weekday.

2. **The `DRIFT_PLAN_ROLE_ARNS` secret on that environment, and nowhere else.** Set it as above with `gh secret set DRIFT_PLAN_ROLE_ARNS --env drift --repo nanohype/landing-zone`, as single-line JSON, and delete any repository-level variable or secret of the same name (`refuse-inherited-config` fails every run while one exists). Until it holds an entry, drift.yml fails at `select-accounts`, which is the intended state while no account has a plan role.

3. **The plan role trusts exactly `environment:drift`, from landing-zone alone.** Set `plan_allowed_subject_claims = ["environment:drift"]` and `github_repos = ["landing-zone"]` in the `github-oidc` leaf of every account that holds a `staging` or `production` environment. The component enforces it, keyed on the account rather than on the leaf's directory (`account_environments`, computed from the tree by envcommon, required and validated against the `env.hcl` vocabulary, as is the leaf's `environment`):

   - `plan_allowed_subject_claims` accepts only exact `environment:<name>` claims: no wildcard, `pull_request` or `ref:` claim.
   - In an account holding `staging` or `production`, a plan role must trust exactly `["environment:drift"]`, and `github_repos` must be exactly `["landing-zone"]`. The plan role renders `repo:<org>/<repo>:environment:drift` for every listed repository, and only landing-zone's `drift` environment carries the main-only branch policy; in any other repository a workflow on any branch that names `environment: drift` creates that environment unprotected. A leaf there that needs a deploy role for other repositories sets `create_plan_role = false`.
   - `environment:plan`, in any letter case, is accepted only in an account holding `development` and nothing else (`workload-development`). ci.yml's PR plan job declares it from any branch, including a same-repository pull request's, and only the development plan role (the `AWS_ROLE_ARN` secret on the `plan` environment) may be reachable from a pull request.
   - `environment:drift` is refused in an account holding no `staging` or `production` environment.
   - An account holding neither `development` alone nor `staging` or `production` (management, fleet, shared-services) gets no plan role: no workflow plans it, so `create_plan_role` must be `false` there.

   The deploy role refuses both `environment:plan` and `environment:drift`. `tofu test` in `components/aws/github-oidc` covers every arm, including a leaf in the development directory of an account that also holds production.

**What stays outside the code.** The `drift` environment's branch policy is a repository setting, and three things can undo it without a pull request: deleting or renaming the environment (the next drift.yml run, from any branch, recreates it unprotected; re-create it with the commands above before anything runs), changing its branch policy, and a workflow on `main` other than drift.yml naming it. A branch policy admits by ref, and a `pull_request_target`, `workflow_run` or `issue_comment` trigger runs with ref `main` whoever caused it. The last is held in CI: `scripts/check-drift-workflow.py` fails any workflow but drift.yml that declares the `drift` environment, literally or through a computed name (outside drift.yml an environment name may be an expression only as `${{ inputs.X }}` over a `workflow_dispatch` choice input whose options exclude drift, since a name such as `${{ github.event.pull_request.head.ref }}` is `drift` for a branch called drift), any other workflow that reads `DRIFT_PLAN_ROLE_ARNS`, and any trigger on drift.yml other than `schedule` and `workflow_dispatch`; its `--self-test` proves each of those shapes is rejected. The first two are not: check the environment with the two `gh api` reads in step 1 after any change to repository environments.

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
4. Plan to verify: `task plan ACCOUNT=workload-development REGION=us-east-1 ENVIRONMENT=development COMPONENT=<component>`
5. Apply: `task apply ACCOUNT=workload-development REGION=us-east-1 ENVIRONMENT=development COMPONENT=<component>`

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

## Retargeting a Region

Moving an account tree between regions has three failure modes no gate catches —
the `region.hcl` local (the directory name is cosmetic), region-bearing values
inside opaque strings such as ARNs, and non-deployable trees that break silently.
See [RB-008](runbooks.md#rb-008-retargeting-an-account-tree-to-a-different-region).

## Backup and Recovery

The `backup` component manages AWS Backup: configurable plans, vault lock for production, KMS encryption, and cross-region copy.

Backup plans are configurable via the `backup_plans` map (schedule, retention, cold storage transition). Email notifications go to `notification_emails`.

### Restore Procedure

1. Open the AWS Backup console
2. Navigate to the vault and find the recovery point
3. Select "Restore" and configure the target resource settings
4. Monitor the restore job in the console

For state file recovery, see [RB-004: Failed Apply](runbooks.md#rb-004-failed-apply--partial-state) in the runbooks.
