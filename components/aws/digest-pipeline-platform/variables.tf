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
  description = "VPC ID. Aurora sits in private subnets in this VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (multi-AZ) for the Aurora subnet group."
  type        = list(string)
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID. Used as the source for Aurora ingress so only pods can reach the DB."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the digest-pipeline Platform tenant runs."
  type        = string
  default     = "tenants-protohype"
}

variable "service_account" {
  description = "Kubernetes ServiceAccount name digest-pipeline's chart binds to."
  type        = string
  default     = "digest-pipeline"
}

variable "ses_sending_domain" {
  description = "Verified SES sending domain (e.g., digest-pipeline.example.com). Required — SES SendEmail policy is scoped to the identity ARN derived from this. Set per-env via the live terragrunt.hcl."
  type        = string
}

variable "deletion_protection" {
  description = "Enable deletion protection on the Aurora cluster. Always true in production."
  type        = bool
  default     = true
}

variable "rds_min_acu" {
  description = "Aurora Serverless v2 minimum ACU."
  type        = number
  default     = 0.5
}

variable "rds_max_acu" {
  description = "Aurora Serverless v2 maximum ACU."
  type        = number
  default     = 2
}

variable "rds_backup_retention_days" {
  description = "RDS automated backup retention window."
  type        = number
  default     = 7
}

variable "voice_baseline_lifecycle_days" {
  description = "Voice-baseline bucket: noncurrent-version expiry days. The baseline corpus is small, append-mostly; long retention is cheap."
  type        = number
  default     = 365
}

variable "raw_aggregations_lifecycle_days" {
  description = "Raw-aggregations bucket: full expiration days. Per-run snapshots stay for compliance windows, then drop."
  type        = number
  default     = 90
}

variable "team" {
  description = "Owning team for this component (drives the Team tag + ArgoCD AppProject scope)."
  type        = string
  default     = "growth"
}

variable "tags" {
  description = "Additional tags merged into every resource."
  type        = map(string)
  default     = {}
}
