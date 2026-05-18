variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region of the AKS cluster"
  type        = string
}

variable "environment" {
  description = "Deployment environment name (dev, staging, production) - used as cluster-secret label and ApplicationSet matrix selector"
  type        = string
}

variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "Endpoint URL of the AKS cluster"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the AKS cluster"
  type        = string
}

variable "vnet_name" {
  description = "Name of the AKS VNet (passed as Helm parameter to addons via cluster-secret label)"
  type        = string
}

variable "team" {
  description = "Team name for resource tagging"
  type        = string
}

variable "gitops_repo_url" {
  description = "Git URL of the AKS GitOps repository"
  type        = string
  default     = "https://github.com/nanohype/aks-gitops.git"
}

variable "gitops_repo_revision" {
  description = "Git branch or tag to track in the GitOps repository"
  type        = string
  default     = "main"
}

variable "gitops_repo_path" {
  description = "Path within the GitOps repository that contains ApplicationSet manifests"
  type        = string
  default     = "applicationsets"
}

variable "cilium_operator_replicas" {
  description = "Number of Cilium operator replicas"
  type        = number
  default     = 1
}

variable "pod_cidr" {
  description = "CIDR block from which Cilium allocates pod IPs (cluster-pool IPAM). MUST be disjoint from the VNet CIDR (network component) and the service CIDR (cluster component). Defaults to 10.244.0.0/16; mask size /24 per node = ~256 nodes worth of /16 with 256 pods/node."
  type        = string
  default     = "10.244.0.0/16"
}

variable "argocd_server_replicas" {
  description = "Number of ArgoCD server replicas"
  type        = number
  default     = 1
}

variable "argocd_repo_replicas" {
  description = "Number of ArgoCD repo server replicas"
  type        = number
  default     = 1
}

variable "argocd_appset_replicas" {
  description = "Number of ArgoCD ApplicationSet controller replicas"
  type        = number
  default     = 1
}
