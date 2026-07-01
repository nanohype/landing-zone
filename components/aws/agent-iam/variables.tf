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

variable "operator_permissions_boundary_arn" {
  description = "Permissions-boundary ARN for the operator role. Fleet vends MUST set this to the vend/hub boundary ARN (published in SSM as /eks-fleet/<env>/fleet-vend/vend_permissions_boundary_arn or /eks-fleet/<env>/fleet-hub/hub_permissions_boundary_arn) — the fleet roles' CreateRole gate rejects an operator role that doesn't carry it. Empty (default) = no boundary (direct terragrunt applies, where the deploy role is not boundary-gated)."
  type        = string
  default     = ""
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
