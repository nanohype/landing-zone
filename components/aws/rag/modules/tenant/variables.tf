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
