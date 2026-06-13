variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
}

variable "portal_hub_role_arn" {
  description = "ARN of the portal hub worker role allowed to assume this spoke role (the only trusted principal)"
  type        = string
}

variable "external_id" {
  description = "sts:ExternalId the hub worker must present when assuming the spoke role (confused-deputy guard; not a secret)"
  type        = string
  default     = "portal"
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
