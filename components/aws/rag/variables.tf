variable "environment" {
  description = "Environment name (development, staging, production)"
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

variable "region" {
  description = "AWS region"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "tenants" {
  description = "Per-tenant RAG configuration"
  type = map(object({
    deletion_protection          = optional(bool, true)
    opensearch_standby_replicas  = optional(bool, true)
    opensearch_index_name        = optional(string, "rag-embeddings")
    opensearch_dimensions        = optional(number, 1024)
    opensearch_engine            = optional(string, "faiss")
    document_versioned           = optional(bool, true)
    document_archive_expiry_days = optional(number, 365)
    conversation_ttl_enabled     = optional(bool, true)
    conversation_pitr            = optional(bool, true)

    # Foundation-model families (IAM resource globs) this tenant's bedrock-api
    # role may invoke. Each expands to the model's foundation-model ARN plus the
    # account's cross-region inference profiles, scoping bedrock:InvokeModel to
    # these models instead of Resource="*". Default covers Claude generation +
    # the Bedrock embedding providers (Titan, Cohere) a RAG tenant retrieves
    # with. Empty list = allow every model ("*"). Covers direct foundation models +
    # system-defined cross-region inference profiles; application inference profiles,
    # provisioned throughput, and custom/imported models are not matched (add their
    # ARNs or use the escape hatch). See the agent-iam bedrock_allowed_model_ids
    # variable for the shared rationale.
    bedrock_allowed_model_ids = optional(list(string), ["anthropic.*", "amazon.titan-embed-*", "cohere.embed-*"])
  }))
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
