variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
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
