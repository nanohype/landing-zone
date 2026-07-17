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
  description = "VPC ID. The Aurora cluster sits in private subnets in this VPC."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs (multi-AZ) for the RDS subnet group."
  type        = list(string)
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID. Used as the source for the Aurora ingress rule so only pods can reach the data plane."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity association targets."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where the competitive-intelligence Platform tenant runs. Matches the Platform CR's metadata.namespace."
  type        = string
  default     = "tenants-protohype"
}

variable "service_account" {
  description = "Kubernetes ServiceAccount name competitive-intelligence's chart binds to. Matches the chart's serviceaccount.yaml output."
  type        = string
  default     = "competitive-intelligence"
}

variable "deletion_protection" {
  description = "Enable deletion protection on the Aurora cluster. Always true in production."
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
