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
| **teardown-gates** | Runs `scripts/check-teardown-gates.py` -- in a component declaring `force_destroy_buckets`, every teardown-gate attribute must resolve permissively when the lever is set, and every protectable resource must carry one. A module without the lever declares why in the script's EXEMPT table. No tflint or checkov rule covers `force_destroy` or `deletion_protection`, and a `tofu test` assert cannot reach a grandchild module's attributes. |
| **tenant-schema-readers** | Runs `scripts/check-tenant-schema-readers.py` -- every field a `tenants` object type declares must be read by a resource in that component. A field with no reader is a control an operator can set, sees accepted, and believes is in force. |
| **plan** | PRs only. Matrix auto-discovered from `live/`. Runs `terragrunt plan -lock=false` to show what would change (credential-gated -- skips green when `AWS_ROLE_ARN` is unset). The credential is the read-only plan role, which cannot write the `.tflock` object `root.hcl`'s `use_lockfile = true` takes, so the plan skips the lock. The PR plan writes nothing and nothing applies its result (it gates on whether the plan runs, not on what it would change), so it never contends with an apply. |

### deploy.yml -- Manual Deploy

**Trigger:** Workflow dispatch (manual).

**Inputs:**
- `account` -- target account directory; must be `workload-<environment>` (see Configuration below)
- `region` -- target region
- `environment` -- development, staging, or production (the `environment` input is a fixed choice)
- `component` -- specific component name or "all"
- `action` -- plan or apply

Uses GitHub environment protection rules -- production requires approval. When `component=all`, runs `terragrunt run --all -- <action>`. Otherwise targets the specific component directory.

The `environment` choice covers only the three workload environments. The management-account `org` components (the [Organization Components](#organization-components) above) are **local-CLI-only** — deploy them with `task apply ACCOUNT=management ENVIRONMENT=org COMPONENT=<component>` under your own admin/SSO credentials. `org` is intentionally not a workflow choice because the management account is applied rarely and by hand.

**Configuration:** two variables on each GitHub Environment (Settings > Environments > `<environment>` > Environment variables), and on nothing broader. The job declares `environment: <environment>`, so each environment carries its own account's values:

| Variable | Value |
|---|---|
| `DEPLOY_ROLE_ARN` | the OIDC deploy role in the `workload-<environment>` account (the `github-oidc` component's `deploy_role_arn` output in that account) |
| `DEPLOY_ACCOUNT_ID` | the 12-digit id of the `workload-<environment>` account. The job passes it to terragrunt as `TERRAGRUNT_ACCOUNT_ID`, and `root.hcl` names the state bucket `<account_id>-<region>-tfstate` from it; without it the bucket would be named after the tracked `account.hcl` placeholder |

A GitHub variable that an environment does not set resolves to the repository's value, then the organization's. That is why these are not `AWS_ROLE_ARN` and `TERRAGRUNT_ACCOUNT_ID`: those are repository variables (the read-only plan role and the account id for `ci.yml`'s plan job), and an environment that forgot its own would silently inherit them. For the same reason a first job, which declares no environment and so sees only repository and organization values, fails the run when either `DEPLOY_*` name is set at one of those levels. Never set them there.

Before any credential is issued, the job fails when the environment sets neither or only one of the two, when `DEPLOY_ACCOUNT_ID` is not 12 digits, when `DEPLOY_ROLE_ARN` is not a role ARN in `DEPLOY_ACCOUNT_ID`'s account, when the `account` input is not `workload-<environment>`, when the `region` input names no directory under that account, or when the `component` input is neither `all` nor a single directory name holding a `terragrunt.hcl` under that environment. After assuming the role it compares the credential's account (`aws sts get-caller-identity`) with `DEPLOY_ACCOUNT_ID` and fails on a mismatch, so a role and an id for two different accounts never reach terragrunt.

The account ids are visible in the run log: the runner prints each step's environment and Variables are not masked. AWS does not treat an account id as a secret; the error messages simply avoid repeating them.

One environment names one account, so the workflow deploys only `live/aws/workload-<environment>/` leaves. The `backup/` and `network/` account directories also hold `development`/`staging`/`production` leaves; run with the workload account's role and id, they would build that account's stack inside the workload account. Deploy them locally under that account's own credentials, the same way as the `org` components: `task apply ACCOUNT=<account> REGION=us-east-1 ENVIRONMENT=<environment> COMPONENT=<component>` with `TERRAGRUNT_ACCOUNT_ID` exported as that account's id.

### destroy.yml -- Manual Destroy

**Trigger:** Workflow dispatch (manual).

**Inputs:**
- `account` -- must be `workload-<environment>` (see Configuration below)
- `region` -- target region
- `environment` -- development or staging only (production excluded)
- `component` -- specific component name or "all"
- `confirm` -- must exactly match the environment name

The confirmation guard (`confirm == environment`) prevents accidental destroys. Runs `terragrunt destroy` or `terragrunt run --all -- destroy`.

**Configuration:** the same environment-only `DEPLOY_ROLE_ARN` and `DEPLOY_ACCOUNT_ID` variables as `deploy.yml`, on the `development` and `staging` GitHub Environments, with the same checks: neither set at repository or organization level, both set on the environment and naming one account, the `account` input equal to `workload-<environment>`, the `component` input `all` or a leaf directory under it, and the assumed credential's account equal to `DEPLOY_ACCOUNT_ID`. The last matters most here: a destroy run with the state of one account and the credential of another sends the state's resource ids to the wrong account, where most of them are simply not found and dropped from state, leaving the real resources running untracked.

### drift.yml -- Drift Detection

**Trigger:** Cron schedule, 6 AM UTC Monday-Friday. Also supports manual dispatch.

**Scope:** every `production` and `staging` live leaf whose account has a plan role, matrix auto-discovered from the tree with `git ls-files` (mirroring `ci.yml`) -- a new production/staging component starts being watched with no workflow edit once its account directory is in the `DRIFT_PLAN_ROLE_ARNS` secret. Development is ephemeral and the `org`/`hub` control planes are covered by their own bring-up, so both are excluded.

**Behavior:** Runs `terragrunt plan -lock=false -detailed-exitcode` for each discovered leaf. Exit code 2 means changes detected (drift). When drift is found, creates or updates a GitHub issue labelled `drift` with the plan output. `select-accounts` and `detect-drift` run in the `drift` GitHub Environment, which admits `main` only: its OIDC subject, `repo:nanohype/landing-zone:environment:drift`, is the one a staging or production plan role trusts, and its secret holds the role map. A dispatch from any other branch stops at `select-accounts`. The environment carries no required reviewers, which would hold every scheduled run for an approval.

- **A plan that cannot run is an error, not "no drift".** Exit code 1 opens or updates an issue labelled `drift-error` and fails the job. A plan role the job cannot assume takes the same path: the `Configure AWS credentials` step continues on error, and the plan step records exit code 1 with a message naming the account directory (never the role ARN), so the account's leaves each get a `drift-error` issue and the run ends red. Issue titles name the account directory and the leaf (`Drift detected: <account>/<env>/<component>`, `Drift check error: <account>/<env>/<component>`), as do the job names, because the same `<env>/<component>` can exist in several accounts; an open issue with the same title is commented on rather than duplicated, and the lookup pages through every open issue with the label. The usual causes are the account's `github-oidc` leaf not applied yet, a trust that does not admit the job's OIDC subject (`environment:drift`), or a `DRIFT_PLAN_ROLE_ARNS` entry naming the wrong role; the AWS error itself is in that step's log.
- **No lock.** `root.hcl` sets `use_lockfile = true`, and a plan that locks writes a `.tflock` object beside the state. The plan role is read-only and cannot write it, so the drift plan runs with `-lock=false`. That is safe because the plan writes nothing and nothing applies its result: it reads state, and its output is a report rather than a saved plan, so it never contends with an apply. An apply at the same moment can only make one report stale, and the next run corrects it.
- **Account ids are masked in the logs.** The repository is public, and every value in `DRIFT_PLAN_ROLE_ARNS` carries a real account id. The map is a secret, so the runner prints it as `***` wherever it appears whole, including the env block of each step that receives it. A secret is masked as a whole, not by its parts, so every job that reads it runs `scripts/mask-drift-role-map.sh` as the first command of the first step that receives it: that registers every twelve-digit run and every role ARN in the map with `::add-mask::` before anything else in the job prints. Masks hold for the rest of the job, so the role step's own output, the `role-to-assume` input the credential step prints, every later step's env block and the raw plan output (which names the state bucket and role ARNs) all show `***` in place of an id or ARN. What stays visible: account directory names, regions, environments and components (in job names, the matrix and the summary), and an account id that is not in the secret at all, such as a cross-account reference in plan output. No job output carries a role value: the runner drops a job output that contains a masked value, so `select-accounts` hands on account directory names only and each `Drift Check` job reads its own role from the secret. This was checked against a local model of the runner's masker (step order, env blocks printed before a step runs, `::add-mask::` taking effect from the next line, masked job outputs dropped), not in a live run.
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

That job passes its step only whether each is set (`true` or `false`), never the value, so it prints neither even when one exists.

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

The OIDC provider and both roles are account-global, so each account gets exactly **one** `github-oidc` leaf, whichever environment directory holds it. For each account directory above:

0. **Create the account's state backend.** None of these accounts has one yet, and the local apply in step 3 cannot initialise without the `<account_id>-us-east-1-tfstate` bucket. Under that account's credentials, run `task init-backend REGION=us-east-1` (it takes the caller's account id, or `ACCOUNT_ID=<id>`), which runs `scripts/init-backend-aws.sh`.
1. **Add the leaf** at `live/aws/<account>/us-east-1/<env>/github-oidc/terragrunt.hcl`, modelled on the `workload-development` one, with `github_repos = ["landing-zone"]`, the deploy-role setting from the table, and the plan role left on (`create_plan_role` defaults to true) with `plan_allowed_subject_claims = ["environment:drift"]`. The component refuses anything else in a `staging` or `production` leaf: the default `["environment:plan"]` is the development trust, and its validation fails the plan rather than ship it here.
2. **Create or reference the OIDC provider.** AWS allows one provider per issuer per account. If the account has none for `token.actions.githubusercontent.com` (check with `aws iam list-open-id-connect-providers` under that account's credentials), leave `create_oidc_provider` at its default `true`; if it already has one, set `create_oidc_provider = false` and the component references it.
3. **Apply it locally with that account's credentials**, the same way as the `org` components: `TERRAGRUNT_ACCOUNT_ID=<that account's id> AWS_PROFILE=<that account's profile> task apply ACCOUNT=<account> REGION=us-east-1 ENVIRONMENT=<env> COMPONENT=github-oidc`. Neither deploy.yml nor drift.yml can apply it: the role it creates is the one they would need.
4. **Record the plan role, once the account's leaves are applied.** Read it with `terragrunt output -raw plan_role_arn` in the leaf directory, and add it to the `DRIFT_PLAN_ROLE_ARNS` secret on the `drift` environment under the account directory's name (edit the local JSON file and re-run the `gh secret set` command above; a secret cannot be read back) only after that account's `staging` and `production` leaves have been applied. An entry arms every one of the account's leaves at once: a leaf never applied plans as all creates and files a `Drift detected` issue (about twenty for a workload account), and one whose dependencies have no state yet fails and files a `drift-error` issue. The next run after the entry is added plans that account's leaves; until then they are listed as skipped.

The leaf itself is a `staging` or `production` leaf, so once it exists drift.yml plans it too, with the plan role it created.

#### Required before any staging or production plan role

A staging or production plan role reads that account's state and data, so it must be reachable from `main` only. Three things make that so, and all three must be in place before the first such leaf is created.

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

3. **The plan role trusts exactly `environment:drift`.** Set `plan_allowed_subject_claims = ["environment:drift"]` in every `staging` or `production` `github-oidc` leaf. The component enforces it: `plan_allowed_subject_claims` accepts only exact `environment:<name>` claims (no wildcard, `pull_request` or `ref:` claim), and its validation reads the leaf's `environment`, so a `staging` or `production` leaf must use exactly `["environment:drift"]`, `environment:plan` is refused outside `development` in any letter case, and `environment:drift` is refused outside `staging` and `production`. `environment:plan` stays the development account's: ci.yml's PR plan job declares it from any branch, including a same-repository pull request's, and only the development plan role (the repository-level `AWS_ROLE_ARN`) may be reachable from a pull request. The deploy role refuses both `environment:plan` and `environment:drift`.

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
