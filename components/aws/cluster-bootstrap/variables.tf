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

variable "oidc_provider_arn" {
  description = "EKS IAM OIDC provider ARN, published to the in-cluster ArgoCD Secret so the eks-agent-platform operator ApplicationSet can wire the operator's IRSA without committing the account ID to git"
  type        = string
}

variable "oidc_issuer" {
  description = "EKS OIDC issuer host without the https:// scheme (e.g. oidc.eks.us-west-2.amazonaws.com/id/<id>)"
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

variable "enable_portal_reader" {
  description = "Create a read-only portal-reader ServiceAccount + durable token so the portal can register this cluster and watch Platform/Tenant CRs without manual token minting"
  type        = bool
  default     = true
}

variable "tenants_repo_url" {
  description = "SSH URL of the private tenants GitOps repo (e.g. git@github.com:nanohype/tenants.git). When set, cluster-bootstrap registers a read-only deploy key on it and writes the matching ArgoCD repository credential so ArgoCD can pull portal-committed tenant manifests. Empty disables the integration. Requires GITHUB_TOKEN in the environment when set."
  type        = string
  default     = ""
}

variable "enable_agent_platform" {
  description = "Label this cluster into the eks-agent-platform operator ApplicationSet, so eks-gitops installs the operator via GitOps using the per-cluster OIDC/role annotations. Set false to install the operator out of band — e.g. the e2e harness builds and helm-installs the operator from a locally-built ECR image until a release is published, and the GitOps install would otherwise race it for ownership of the operator's resources."
  type        = bool
  default     = true
}
