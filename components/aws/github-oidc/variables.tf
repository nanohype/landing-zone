# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string
  default     = ""
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
}

variable "allowed_subject_claims" {
  description = <<-EOT
    GitHub OIDC `sub` claim suffixes the deploy role trusts, applied to every repo in
    github_repos (final subject = repo:<org>/<repo>:<claim>). Default is
    environment-gated deploys + tag pushes — "environment:*" (any GitHub Environment,
    the recommended deploy-gating context) and "ref:refs/tags/*" (release tags). This
    deliberately EXCLUDES a bare ":*", which would also trust pull_request and every
    branch context — a fork's PR or an untrusted branch must never assume a deploy
    role. Narrow further (e.g. "environment:production") or add contexts (e.g.
    "ref:refs/heads/main") as the CI model requires. Setting an entry to "*" restores
    the broad ":*" — an explicit, auditable opt-out.
  EOT
  type        = list(string)
  default     = ["environment:*", "ref:refs/tags/*"]

  validation {
    condition     = length(var.allowed_subject_claims) > 0
    error_message = "allowed_subject_claims must contain at least one claim; an empty list would render an empty sub condition, which AWS drops — making the deploy role assumable by any GitHub Actions workflow."
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
  description = "Create the read-only plan role the CI plan matrix assumes on pull requests. Separate from the deploy role because the plan matrix runs on `pull_request`, a context the deploy role must never trust."
  type        = bool
  default     = true
}

variable "plan_role_name" {
  description = "Name of the GitHub Actions plan role"
  type        = string
  default     = "github-actions-plan"
}

variable "plan_allowed_subject_claims" {
  description = <<-EOT
    GitHub OIDC `sub` claim suffixes the PLAN role trusts. Default is a single
    GitHub Environment ("environment:plan"), which is the escape hatch the deploy
    leaf prescribes for jobs needing a role from a non-environment context: the
    job declares `environment: plan`, its token presents
    repo:<org>/<repo>:environment:plan, and the environment can carry required
    reviewers so an untrusted branch waits for a human before any credential is
    issued. Deliberately NOT "pull_request" and NOT a bare branch claim — either
    would hand a credential to any PR the moment it opens, on a public repo.
  EOT
  type        = list(string)
  default     = ["environment:plan"]

  validation {
    condition     = length(var.plan_allowed_subject_claims) > 0
    error_message = "plan_allowed_subject_claims must contain at least one claim; an empty list would render an empty sub condition, which AWS drops — making the plan role assumable by any GitHub Actions workflow."
  }

  validation {
    condition     = !contains(var.plan_allowed_subject_claims, "*")
    error_message = "plan_allowed_subject_claims must not contain a bare \"*\": that trusts every context including pull_request from any branch. Name the contexts explicitly."
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
