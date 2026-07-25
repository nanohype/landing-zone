variable "environment" {
  description = "Environment name (development, staging, production). A segment of the staging bucket name, the import role name and the SSM discovery prefix, so two environments sharing one account do not collide."
  type        = string

  # Format contract, not a closed enum — same rationale as the other components.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

variable "region" {
  description = "AWS region. The staging bucket and the import service role are region-scoped — S3's namespace is global and IAM's is account-global — so the region is part of every derived name. The imported model itself is stored and managed by Bedrock, not by this component."
  type        = string
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

variable "staging_noncurrent_expiration_days" {
  description = "Delete non-current versions of staged weight objects after N days. Staged Hugging Face weight files are large and re-uploadable, so superseded versions are expired promptly."
  type        = number
  default     = 7
}
