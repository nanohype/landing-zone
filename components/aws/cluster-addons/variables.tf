variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "velero_enabled" {
  description = "Enable Velero IRSA role and S3 bucket"
  type        = bool
  default     = true
}

variable "opencost_enabled" {
  description = "Enable OpenCost IRSA role"
  type        = bool
  default     = true
}

variable "keda_enabled" {
  description = "Enable KEDA IRSA role"
  type        = bool
  default     = true
}

variable "argo_events_enabled" {
  description = "Enable Argo Events IRSA role"
  type        = bool
  default     = true
}

variable "argo_workflows_enabled" {
  description = "Enable Argo Workflows IRSA role and S3 bucket"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
