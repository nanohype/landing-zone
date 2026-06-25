variable "environment" {
  description = "Environment name (dev, staging, production)."
  type        = string
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
  description = "Aurora Serverless v2 maximum ACU. Production typically wants 8-16; dev/staging stays at 2."
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
