variable "environment" {
  description = "Environment name (development, staging, production)."
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
  description = "AWS region."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID. slack-knowledge-bot's RDS Aurora + ElastiCache Redis sit in private subnets in this VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (multi-AZ) for the RDS subnet group and ElastiCache subnet group."
  type        = list(string)
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID. Used as the source for Aurora + Redis ingress rules so only pods can reach the data plane."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the slack-knowledge-bot Platform tenant runs. Matches the Platform CR's metadata.namespace."
  type        = string
  default     = "tenants-protohype"
}

variable "service_account" {
  description = "Kubernetes ServiceAccount name slack-knowledge-bot's chart binds to. Matches the chart's serviceaccount.yaml output."
  type        = string
  default     = "slack-knowledge-bot"
}

variable "deletion_protection" {
  description = "Enable deletion protection on the DDB tables + Aurora cluster. Always true in production."
  type        = bool
  default     = true
}

variable "point_in_time_recovery" {
  description = "Enable PITR on the DDB tables."
  type        = bool
  default     = true
}

variable "rds_min_acu" {
  description = "Aurora Serverless v2 minimum ACU. 0.5 is the floor for serverless-v2."
  type        = number
  default     = 0.5
}

variable "rds_max_acu" {
  description = "Aurora Serverless v2 maximum ACU. Production typically wants 8-16; development/staging stays at 2."
  type        = number
  default     = 2
}

variable "rds_backup_retention_days" {
  description = "RDS automated backup retention window."
  type        = number
  default     = 7
}

variable "redis_node_type" {
  description = "ElastiCache Redis node type. cache.t4g.micro is development-grade; production uses cache.t4g.small or cache.m7g.large depending on throughput."
  type        = string
  default     = "cache.t4g.micro"
}

variable "redis_num_cache_clusters" {
  description = "Number of Redis cache clusters in the replication group. 1 for development (no failover), 2 for production (one read replica + automatic failover)."
  type        = number
  default     = 1
}

variable "redis_multi_az" {
  description = "Enable multi-AZ failover on the Redis replication group. Always true in production."
  type        = bool
  default     = false
}

variable "audit_ttl_days" {
  description = "DDB TTL window for the audit table. 90d hot, then S3 lifecycle takes over to long-term."
  type        = number
  default     = 90
}

variable "audit_s3_lifecycle_days" {
  description = "S3 audit bucket expiration window."
  type        = number
  default     = 365
}

variable "audit_s3_intelligent_tiering_days" {
  description = "Days before audit objects transition to Intelligent-Tiering."
  type        = number
  default     = 90
}

variable "team" {
  description = "Owning team for tagging."
  type        = string
  default     = "protohype"
}

variable "tags" {
  description = "Additional tags merged into every resource."
  type        = map(string)
  default     = {}
}
