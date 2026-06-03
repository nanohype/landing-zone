variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "hub_role_arn" {
  description = "ARN of the management-account eks-fleet-crossplane role allowed to assume this vend role (the only trusted principal)"
  type        = string
}

variable "external_id" {
  description = "sts:ExternalId the hub must present when assuming the vend role (confused-deputy guard; not a secret)"
  type        = string
  default     = "eks-fleet"
}

variable "team" {
  description = "Owning team tag"
  type        = string
  default     = "platform"
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
