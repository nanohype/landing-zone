variable "environment" {
  description = "Environment name (dev, staging, production)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS cluster OIDC provider ARN (from the cluster component)"
  type        = string
}

variable "oidc_issuer" {
  description = "EKS cluster OIDC issuer host, no scheme (oidc.eks.<region>.amazonaws.com/id/<id>)"
  type        = string
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
