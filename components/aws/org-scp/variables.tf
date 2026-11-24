variable "environment" {
  description = "Environment name"
  type        = string

  # Format contract, not a closed enum: the platform legitimately uses development, staging,
  # production, prod, hub, org, management, and per-workload derivations, so pinning a
  # fixed set would reject valid environments. This still catches empty/uppercase/typo'd
  # values before they flow into resource names, tags, and SSM paths.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

variable "allowed_regions" {
  description = "Regions the RegionRestriction and DenyBedrockEgressOutsideRegion guardrails allow; every request outside them is denied."
  type        = list(string)

  validation {
    condition     = length(var.allowed_regions) > 0 && alltrue([for r in var.allowed_regions : can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", r))])
    error_message = "allowed_regions must name at least one region, each an AWS region code such as us-east-1."
  }
}

variable "guardrail_targets" {
  description = "Where each shipped guardrail binds: guardrail name (see guardrails.tf) -> OU or account ids. A guardrail with no entry is created and attached nowhere."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for name in keys(var.guardrail_targets) : contains(keys(local.guardrails), name)])
    error_message = "guardrail_targets names a guardrail this component does not ship; the names are the keys of local.guardrails in guardrails.tf."
  }
}

variable "policies" {
  description = "Operator-authored Service Control Policies to create and attach beside the shipped guardrails"
  type = map(object({
    description = string
    policy      = string
    target_ids  = list(string)
  }))
  default = {}

  validation {
    condition     = length(setintersection(keys(var.policies), keys(local.guardrails))) == 0
    error_message = "a policy in var.policies may not reuse a shipped guardrail's name; it would replace the guardrail. Bind a guardrail with guardrail_targets instead."
  }
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
