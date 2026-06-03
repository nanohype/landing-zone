variable "environment" {
  description = "Environment name for the management hub (tags + SSM path)"
  type        = string
  default     = "management"
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN of the management (hub) EKS cluster — from the cluster component"
  type        = string
}

variable "oidc_issuer" {
  description = "OIDC issuer host of the hub cluster, no scheme (oidc.eks.<region>.amazonaws.com/id/<id>)"
  type        = string
}

variable "state_bucket_name" {
  description = "S3 bucket holding the vended clusters' OpenTofu state (provider-opentofu backend)"
  type        = string
  default     = "nanohype-eks-fleet-tfstate"
}

variable "team" {
  description = "Owning team tag"
  type        = string
  default     = "platform"
}

variable "tags" {
  description = "Common resource tags"
  type        = map(string)
  default     = {}
}
