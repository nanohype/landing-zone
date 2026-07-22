variable "environment" {
  description = "Environment name (development, staging, production)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

# Uniform envcommon interface variable — every component declares it; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

variable "profile_id" {
  description = <<-EOT
    The Route53 Profile ID shared to this account over RAM by the shared-dns owner component.
    Associating it with vpc_id makes every private zone the Profile carries resolve inside that
    VPC. Resolved from shared-dns's profile_id output (a terragrunt dependency) or its SSM
    parameter (/platform/<env>/shared-dns/profile-id).
  EOT
  type        = string

  validation {
    condition     = can(regex("^rp-[0-9a-z]+$", var.profile_id))
    error_message = "profile_id must be a Route53 Profile id (rp-...)."
  }
}

variable "vpc_id" {
  description = "The cluster VPC to associate the shared Profile with. Every private zone the Profile carries resolves inside this VPC after association."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC id (vpc-...)."
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
