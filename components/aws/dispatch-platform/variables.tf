variable "environment" {
  description = "Environment name (dev, staging, production)."
  type        = string
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

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN."
  type        = string
}

variable "oidc_issuer" {
  description = "EKS OIDC issuer URL without the https:// prefix."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the dispatch Platform tenant runs."
  type        = string
  default     = "tenants-protohype"
}

variable "service_account" {
  description = "Kubernetes ServiceAccount name dispatch's chart binds to."
  type        = string
  default     = "dispatch"
}

variable "ses_sending_domain" {
  description = "Verified SES sending domain (e.g., dispatch.example.com). Required — SES SendEmail policy is scoped to the identity ARN derived from this. Set per-env via the live terragrunt.hcl."
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
  description = "Owning team for tagging."
  type        = string
  default     = "protohype"
}

variable "tags" {
  description = "Additional tags merged into every resource."
  type        = map(string)
  default     = {}
}
