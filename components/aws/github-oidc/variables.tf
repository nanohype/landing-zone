# Uniform envcommon interface variable, and read here: it must be one of the
# environments the account holds (account_environments), and its spelling is
# held to the env.hcl vocabulary so a misspelt environment cannot fall outside
# the rules plan_allowed_subject_claims applies.
variable "environment" {
  description = "Environment name of the leaf (development, staging, production, hub, org or shared), injected by live/root.hcl from env.hcl. Must be one of account_environments. The plan role's trust is decided by the account (account_environments), not by this value; see plan_allowed_subject_claims."
  type        = string

  validation {
    condition     = contains(["development", "staging", "production", "hub", "org", "shared"], var.environment)
    error_message = "environment must be one of development, staging, production, hub, org or shared, spelled exactly as env.hcl spells it: the plan role's trust rules are keyed on these names, and a value outside them (\"Production\", \"prod\", \"\") would fall outside every rule."
  }
}

variable "account_environments" {
  description = <<-EOT
    Every environment the leaf's AWS account holds: the `environment` of each
    env.hcl under the account directory (live/aws/<account>/<region>/<env>/env.hcl),
    computed from the tree by live/_envcommon/aws/github-oidc.hcl. Required, with
    no default, so a caller cannot leave it out and fall into a permissive arm.

    The plan role's trust is decided by this, not by `environment`. The roles are
    account-global and the account's one state bucket holds every environment's
    state, so the trust boundary is the account: a github-oidc leaf in the
    development directory of an account that also holds production (network,
    backup) reads production state just as a leaf in its production directory
    would. See plan_allowed_subject_claims for the three arms.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.account_environments) > 0
    error_message = "account_environments must name at least one environment: the environments the account holds decide which GitHub Environment the plan role may trust."
  }

  validation {
    condition     = alltrue([for e in var.account_environments : contains(["development", "staging", "production", "hub", "org", "shared"], e)])
    error_message = "account_environments entries must each be one of development, staging, production, hub, org or shared, spelled exactly as env.hcl spells them."
  }

  validation {
    # The leaf's own environment is one the account holds by construction when
    # envcommon computes the list. A caller passing a list that leaves it out is
    # describing some other account.
    condition     = contains(var.account_environments, var.environment)
    error_message = "account_environments must contain the leaf's own environment: it lists every environment of the account the leaf sits in, which includes the leaf's."
  }
}

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
  default     = ""
}

variable "team" {
  description = "Owning team for this component"
  type        = string
  default     = "platform"
}

variable "tags" {
  description = "Default tags injected by the root config"
  type        = map(string)
  default     = {}
}

variable "github_org" {
  description = "GitHub organization that owns the CI repos"
  type        = string
  default     = "nanohype"

  validation {
    # The org lands verbatim in every role's StringLike `sub` condition, where `*`
    # and `?` are wildcards. A wildcard here would widen every trust this
    # component renders to other organizations, so only a literal GitHub org name
    # (letters, digits, hyphens) is accepted.
    condition     = can(regex("^[A-Za-z0-9-]+$", var.github_org))
    error_message = "github_org must be a literal GitHub organization name (letters, digits and hyphens only); a \"*\" or \"?\" would be a StringLike wildcard in every role's trust, admitting other organizations' workflows."
  }
}

variable "github_repos" {
  description = "Repos whose Actions workflows may assume the deploy role (trust is scoped to repo:<org>/<repo>:<claim> for each allowed_subject_claims entry)."
  type        = list(string)
  default     = ["landing-zone"]

  validation {
    # An empty list renders an empty `sub` condition, which AWS silently drops —
    # leaving only the `aud` check and letting ANY GitHub Actions token assume
    # the role. Require at least one repo.
    condition     = length(var.github_repos) > 0
    error_message = "github_repos must contain at least one repo; an empty list would make the deploy role assumable by any GitHub Actions workflow."
  }

  validation {
    # Each repo lands verbatim in the deploy and plan roles' StringLike `sub`
    # condition. "landing-zone*" would render repo:<org>/landing-zone*:<claim>,
    # which also matches repo:<org>/landing-zone:environment:plan — a wildcard here
    # gets past every check on allowed_subject_claims. Only literal GitHub repo
    # names (letters, digits, ".", "_", "-") are accepted.
    condition     = alltrue([for r in var.github_repos : can(regex("^[A-Za-z0-9._-]+$", r))])
    error_message = "github_repos entries must be literal GitHub repository names (letters, digits, \".\", \"_\" and \"-\" only); a \"*\" or \"?\" is a StringLike wildcard in the trust policy and would widen the deploy role to other repos and contexts."
  }

  validation {
    # The plan role renders repo:<org>/<repo>:environment:drift for EVERY repo
    # here. The main-only branch policy that makes that claim safe exists on
    # landing-zone's own `drift` environment only. In another repository a
    # workflow on any branch that names `environment: drift` creates that
    # environment, unprotected, and would assume this account's plan role. So a
    # plan role in an account holding staging or production trusts landing-zone
    # alone; a deploy role for another repo there takes create_plan_role = false
    # and its own leaf.
    condition = (!var.create_plan_role ||
      length(setintersection(toset(var.account_environments), toset(["staging", "production"]))) == 0 ||
    var.github_repos == tolist(["landing-zone"]))
    error_message = "In an account that holds a staging or production environment, a leaf that creates the plan role must set github_repos to exactly [\"landing-zone\"]: the plan role trusts environment:drift in every listed repo, and only landing-zone's drift environment carries the main-only branch policy. In any other repository, a workflow on any branch that names `environment: drift` creates that environment unprotected and would assume this account's plan role. Set create_plan_role = false on a leaf that needs other repos."
  }
}

variable "allowed_subject_claims" {
  description = <<-EOT
    GitHub OIDC `sub` claim suffixes the deploy role trusts, applied to every repo in
    github_repos (final subject = repo:<org>/<repo>:<claim>). Every entry must be an
    exact GitHub Environment claim, "environment:<name>", with no wildcard. Default
    is the environments the workflows that need this role declare: "development",
    "staging" and "production" (deploy.yml, and destroy.yml for the first two) and
    "e2e" (e2e.yml). The default is the union across accounts; each account's leaf
    should narrow it to the environments that deploy into that account, so the
    least-protected environment never reaches another account's deploy role.

    Validation refuses, rather than documents:
      - any wildcard ("environment:*", "environment:prod*", "*"). GitHub creates an
        environment, with no protection rules, the first time a workflow names it,
        so a wildcard admits any environment name a branch's workflow invents.
      - "environment:plan" and "environment:drift" in any letter case. ci.yml's PR
        plan job declares the first and drift.yml the second, and both belong to
        the read-only plan role (plan_allowed_subject_claims).
      - any claim that is not an environment: "pull_request", "ref:..." (branch
        or tag refs) and the like. A ref or pull_request claim is held by anyone
        who can push that ref or open that pull request, with no environment rule
        in between.

    The trust names environments, not refs: the `sub` of a job that declares an
    environment carries only the environment, so any branch can present it. Each
    trusted environment must therefore exist in the repository settings with a
    deployment-branch policy (main or protected branches), and the ones that reach
    production data with required reviewers. To trust a new context, give the job
    its own environment, protect that environment, and add its claim here.
  EOT
  type        = list(string)
  default     = ["environment:development", "environment:staging", "environment:production", "environment:e2e"]

  validation {
    condition     = length(var.allowed_subject_claims) > 0
    error_message = "allowed_subject_claims must contain at least one claim; an empty list would render an empty sub condition, which AWS drops — making the deploy role assumable by any GitHub Actions workflow."
  }

  validation {
    # An allowlist, not a denylist: IAM evaluates the sub with StringLike, where `*`
    # and `?` are wildcards, and GitHub auto-creates an unprotected environment the
    # first time a workflow names one. Only an exact environment name is a context
    # whose protection rules can be checked in the repository settings.
    condition     = alltrue([for c in var.allowed_subject_claims : can(regex("^environment:[^*?]+$", c))])
    error_message = "allowed_subject_claims entries must each be an exact GitHub Environment claim, \"environment:<name>\", with no \"*\" or \"?\". A wildcard admits any environment name a branch's workflow declares, and GitHub creates that environment, unprotected, the first time a workflow names it. A pull_request or ref: claim is held by anyone who can open that pull request or push that ref. Give the job its own protected environment instead."
  }

  validation {
    # GitHub environment names are case-insensitive: a job declaring
    # `environment: Plan` runs under the plan environment's rules, which admit any
    # branch. Refuse every casing.
    condition     = alltrue([for c in var.allowed_subject_claims : lower(c) != "environment:plan"])
    error_message = "allowed_subject_claims must not contain \"environment:plan\" in any letter case: ci.yml's PR plan job declares that environment from any branch, so trusting it hands the deploy role to every branch. The plan role (plan_allowed_subject_claims) is the one that trusts it."
  }

  validation {
    # The drift environment is main-only, but every drift.yml job that declares it
    # exists to read: it is the read-only plan role's environment in staging and
    # production. A deploy role trusting it would hand the role that provisions
    # and destroys the substrate to a scheduled job that never needs it.
    condition     = alltrue([for c in var.allowed_subject_claims : lower(c) != "environment:drift"])
    error_message = "allowed_subject_claims must not contain \"environment:drift\" in any letter case: drift.yml declares that environment to assume the read-only plan role of a staging or production account (plan_allowed_subject_claims), and nothing in it deploys."
  }
}

variable "create_deploy_role" {
  description = "Create the deploy role. Set false on a leaf that manages only the other roles this component offers, so applying it creates no deploy role."
  type        = bool
  default     = true
}

variable "role_name" {
  description = "Name of the GitHub Actions deploy role"
  type        = string
  default     = "github-actions-deploy"
}

variable "create_oidc_provider" {
  description = "Create the GitHub Actions OIDC provider. Set false to reference an existing provider in the account (only one per issuer is allowed)."
  type        = bool
  default     = true
}

variable "oidc_thumbprints" {
  description = "GitHub Actions OIDC TLS thumbprints. AWS does not verify these for this issuer, but the provider resource requires a value."
  type        = list(string)
  default = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fce",
  ]
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary capping the deploy role. Empty = none (recommended to set in sensitive accounts)."
  type        = string
  default     = ""
}

variable "managed_policy_arns" {
  description = "Managed policies to attach to the deploy role. Empty by default — the role is inert until you attach what CI needs (e.g. AdministratorAccess with a permissions boundary, or a scoped set) when adopting the GitHub Actions path. The repo-scoped trust is the primary control."
  type        = list(string)
  default     = []
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds for the deploy role"
  type        = number
  default     = 3600
}

variable "create_plan_role" {
  description = "Create the read-only plan role: in the development account, the one ci.yml's PR plan job assumes; in an account holding staging or production, the one drift.yml assumes from the main-only drift environment. Separate from the deploy role because the PR plan job runs on `pull_request`, a context the deploy role must never trust. Must be false in an account that holds neither (see plan_allowed_subject_claims)."
  type        = bool
  default     = true

  # The `||` stays at the end of the line: checkov's HCL parser cannot read a line
  # that begins with an operator.
  validation {
    # An account that is neither development-only nor holds staging or
    # production (the management, fleet and shared-services accounts) has no
    # workflow that plans it, so it has no environment whose protection rules
    # this role could rest on. It gets no plan role rather than an invented one.
    condition = (!var.create_plan_role || toset(var.account_environments) == toset(["development"]) ||
    length(setintersection(toset(var.account_environments), toset(["staging", "production"]))) > 0)
    error_message = "This account holds neither development alone nor a staging or production environment, so no workflow plans it and no GitHub Environment is designed to reach its plan role. Set create_plan_role = false on this leaf."
  }
}

variable "plan_role_name" {
  description = "Name of the GitHub Actions plan role"
  type        = string
  default     = "github-actions-plan"
}

variable "plan_allowed_subject_claims" {
  description = <<-EOT
    GitHub OIDC `sub` claim suffixes the PLAN role trusts, applied to every repo in
    github_repos (final subject = repo:<org>/<repo>:<claim>). Every entry must be an
    exact GitHub Environment claim, "environment:<name>", with no wildcard, for the
    reasons allowed_subject_claims gives: GitHub creates an environment, with no
    protection rules, the first time a workflow names it, and a pull_request or
    ref: claim is held by anyone who can open that pull request or push that ref.

    Which environment depends on the ACCOUNT (account_environments), not on the
    leaf's directory, and the validation enforces it when create_plan_role is true:
      - an account holding a staging or production environment (workload-staging,
        workload-production, network, backup): exactly ["environment:drift"], with
        github_repos exactly ["landing-zone"]. drift.yml declares that environment,
        and its deployment-branch policy admits main only, so the account-wide read
        this role carries (every environment's state included) is never reachable
        from a pull request or another branch. "environment:plan" is refused in
        any letter case, whichever environment directory the leaf sits in:
        trusting it would hand staging and production data to every branch that
        can run ci.yml.
      - an account holding development and nothing else (workload-development):
        the default, "environment:plan". ci.yml's PR plan job declares it from any
        branch, including a same-repository pull request's, which is acceptable
        for the development account and nowhere else. "environment:drift" is
        refused here.
      - any other account (one holding only hub, org or shared environments, or
        development beside one of them): no plan role. No workflow plans those
        accounts, so set create_plan_role = false.
  EOT
  type        = list(string)
  default     = ["environment:plan"]

  validation {
    condition     = length(var.plan_allowed_subject_claims) > 0
    error_message = "plan_allowed_subject_claims must contain at least one claim; an empty list would render an empty sub condition, which AWS drops — making the plan role assumable by any GitHub Actions workflow."
  }

  validation {
    # The same allowlist allowed_subject_claims carries: an exact environment is the
    # only context whose protection rules can be checked in the repository settings.
    condition     = alltrue([for c in var.plan_allowed_subject_claims : can(regex("^environment:[^*?]+$", c))])
    error_message = "plan_allowed_subject_claims entries must each be an exact GitHub Environment claim, \"environment:<name>\", with no \"*\" or \"?\". A wildcard admits any environment name a branch's workflow declares, and GitHub creates that environment, unprotected, the first time a workflow names it. A pull_request or ref: claim is held by anyone who can open that pull request or push that ref."
  }

  # The conditions below keep each `||` at the end of a line, never at the start
  # of one: checkov's HCL parser (python-hcl2) cannot read a line that begins
  # with an operator, and a file it cannot parse fails the Security Scan.

  validation {
    # A plan role in an account holding staging or production reads that state
    # and data, whichever environment directory its leaf sits in. Only the
    # main-only drift environment may reach it; the PR plan environment, which
    # any branch can declare, never may.
    condition = (!var.create_plan_role ||
      length(setintersection(toset(var.account_environments), toset(["staging", "production"]))) == 0 ||
    var.plan_allowed_subject_claims == tolist(["environment:drift"]))
    error_message = "In an account that holds a staging or production environment, plan_allowed_subject_claims must be exactly [\"environment:drift\"], whichever environment directory the leaf sits in: the plan role reads the account's one state bucket, every environment's state included. drift.yml declares environment:drift, whose deployment-branch policy admits main only. \"environment:plan\" is declared by ci.yml's PR plan job from any branch, so trusting it would hand this account's state and data to every branch that can run ci.yml."
  }

  validation {
    # environment:plan belongs to the development account's plan role alone (the
    # repository-level AWS_ROLE_ARN ci.yml's PR plan job assumes), in any casing,
    # because GitHub environment names are case-insensitive.
    condition = (!var.create_plan_role || toset(var.account_environments) == toset(["development"]) ||
    alltrue([for c in var.plan_allowed_subject_claims : lower(c) != "environment:plan"]))
    error_message = "plan_allowed_subject_claims may contain \"environment:plan\" (in any letter case) only in an account holding development and nothing else: ci.yml's PR plan job declares that environment from any branch, and only the development account's plan role may be reachable from a pull request."
  }

  validation {
    # environment:drift belongs to plan roles in accounts holding staging or
    # production alone: drift.yml plans only those leaves, so in any other account
    # the claim would trust a job that never assumes the role.
    condition = (!var.create_plan_role ||
      length(setintersection(toset(var.account_environments), toset(["staging", "production"]))) > 0 ||
    alltrue([for c in var.plan_allowed_subject_claims : lower(c) != "environment:drift"]))
    error_message = "plan_allowed_subject_claims may contain \"environment:drift\" (in any letter case) only in an account holding a staging or production environment: drift.yml plans only those leaves, so no other plan role has a drift job to trust."
  }
}

variable "plan_managed_policy_arns" {
  description = "Managed policies attached to the plan role. Defaults to ReadOnlyAccess — a plan reads, it does not write. Note this is account-wide read INCLUDING the Terraform state bucket, whose objects hold plaintext values for any attribute a provider does not mark sensitive; that is inherent to letting CI plan at all, since plan reads state."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
}

variable "create_ecr_public_pull_role" {
  description = "Create the ECR Public pull role, whose only permissions mint a public.ecr.aws authorization token so CI pulls are metered against this account rather than the runner's shared address."
  type        = bool
  default     = false
}

variable "ecr_public_pull_role_name" {
  description = "Name of the GitHub Actions ECR Public pull role"
  type        = string
  default     = "github-actions-ecr-public-pull"
}

variable "ecr_public_pull_repos" {
  description = "Repos whose Actions workflows may assume the ECR Public pull role (trust is scoped to repo:<org>/<repo>:<claim> for each ecr_public_pull_subject_claims entry). Independent of github_repos: the repos that pull public images are not the repos that deploy this substrate."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.create_ecr_public_pull_role || length(var.ecr_public_pull_repos) > 0
    error_message = "ecr_public_pull_repos must contain at least one repo when create_ecr_public_pull_role is true; an empty list would render an empty sub condition, which AWS drops — making the pull role assumable by any GitHub Actions workflow."
  }
}

variable "ecr_public_pull_subject_claims" {
  description = <<-EOT
    GitHub OIDC `sub` claim suffixes the ECR Public pull role trusts, applied to every
    repo in ecr_public_pull_repos. Default is the two contexts a CI workflow runs in
    on its own repo: "pull_request" (a pull request from a branch of that repo; GitHub
    issues no OIDC token to one from a fork) and "ref:refs/heads/main" (a push to
    main, a schedule, or a dispatch on main). pull_request is acceptable here and on
    no other role this component offers, because this role reads only public data.
    Add contexts the workflows run in, such as a merge queue's
    "ref:refs/heads/gh-readonly-queue/main/*".
  EOT
  type        = list(string)
  default     = ["pull_request", "ref:refs/heads/main"]

  validation {
    condition     = length(var.ecr_public_pull_subject_claims) > 0
    error_message = "ecr_public_pull_subject_claims must contain at least one claim; an empty list would render an empty sub condition, which AWS drops — making the pull role assumable by any GitHub Actions workflow."
  }

  validation {
    condition     = !contains(var.ecr_public_pull_subject_claims, "*")
    error_message = "ecr_public_pull_subject_claims must not contain a bare \"*\": name the contexts the pulling workflows run in."
  }
}
