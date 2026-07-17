variable "environment" {
  description = "Environment name"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "tenant_id" {
  description = "Unique tenant identifier"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,22}[a-z0-9])?$", var.tenant_id))
    error_message = "tenant_id must be a lowercase RFC-1123 label of at most 24 characters: it is concatenated into S3 bucket (63-char) and IAM role (64-char) names. The account-qualified bucket name <env>-<domain>-<tenant_id>-<account>-<purpose> is the tightest; the exact per-component budget for a full-word environment is enforced by the component-level tenants validation."
  }
}

variable "tenant_config" {
  description = "Tenant-specific RAG configuration"
  type = object({
    deletion_protection          = optional(bool, true)
    opensearch_standby_replicas  = optional(bool, true)
    opensearch_index_name        = optional(string, "rag-embeddings")
    opensearch_dimensions        = optional(number, 1024)
    opensearch_engine            = optional(string, "faiss")
    document_versioned           = optional(bool, true)
    document_archive_expiry_days = optional(number, 365)
    conversation_ttl_enabled     = optional(bool, true)
    conversation_pitr            = optional(bool, true)

    # Foundation-model families (IAM resource globs) the bedrock-api role may
    # invoke; expanded to foundation-model + inference-profile ARNs so
    # bedrock:InvokeModel is scoped to these models, never Resource="*". Empty
    # list = allow every model.
    bedrock_allowed_model_ids = optional(list(string), ["anthropic.*", "amazon.titan-embed-*", "cohere.embed-*"])
  })
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
