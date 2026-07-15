variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
  default     = ""
}

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
  description = "GitHub Actions OIDC TLS thumbprints. AWS no longer verifies these for this issuer, but the provider resource requires a value."
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
