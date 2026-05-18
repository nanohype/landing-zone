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

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "EKS cluster CA certificate (base64-encoded)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for the EKS cluster"
  type        = string
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.19.1"
}

variable "cilium_operator_replicas" {
  description = "Number of Cilium operator replicas"
  type        = number
  default     = 2
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "9.4.5"
}

variable "argocd_server_replicas" {
  description = "Number of ArgoCD server replicas"
  type        = number
  default     = 2
}

variable "argocd_repo_replicas" {
  description = "Number of ArgoCD repo server replicas"
  type        = number
  default     = 2
}

variable "argocd_appset_replicas" {
  description = "Number of ArgoCD ApplicationSet controller replicas"
  type        = number
  default     = 2
}

variable "gitops_repo_url" {
  description = "GitOps repository URL"
  type        = string
  default     = "https://github.com/nanohype/eks-gitops.git"
}

variable "gitops_repo_branch" {
  description = "GitOps repository branch"
  type        = string
  default     = "main"
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
