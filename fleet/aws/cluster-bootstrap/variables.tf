# Inputs a provider-opentofu Workspace passes (eks-fleet's Cluster composition,
# second Workspace). Cluster identity comes from the first (cluster-stack)
# Workspace's outputs, surfaced through Cluster.status.

variable "region" {
  description = "AWS region"
  type        = string
}

variable "environment" {
  description = "Environment tier (dev, staging, production) — prefixes resource names + tags"
  type        = string
}

variable "team" {
  description = "Owning team (tagging + ownership)"
  type        = string
}

variable "assume_role_arn" {
  description = "Cross-account role to assume for the AWS-side work (agent-iam, data sources). Empty = use the runner's own identity (same-account)."
  type        = string
  default     = ""
}

variable "external_id" {
  description = "sts:ExternalId presented when assuming the cross-account vend role (must match the fleet-vend trust; ignored same-account)"
  type        = string
  default     = "eks-fleet"
}

# --- cluster identity (from cluster-stack outputs / Cluster.status) ----------
variable "cluster_name" {
  description = "EKS cluster name (the vended cluster's resolved name)"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  type        = string

  # Patched from Cluster.status.clusterEndpoint, which is empty until the
  # cluster-stack Workspace reaches Ready. The composition renders this Workspace
  # immediately (function-patch-and-transform can't gate on another resource), so
  # early reconciles run with an empty endpoint — this turns that into a clear
  # "waiting for the cluster" message instead of a cryptic k8s provider error.
  # The clean gate (conditional render) rides the planned function-go-templating
  # migration. All status-sourced vars populate together, so guarding the endpoint
  # alone is enough.
  validation {
    condition     = var.cluster_endpoint != ""
    error_message = "cluster_endpoint is empty — the cluster is not Ready yet. This Workspace runs after cluster-stack populates Cluster.status; it converges automatically once the cluster's API endpoint is published."
  }
}

variable "cluster_certificate_authority_data" {
  description = "EKS cluster CA certificate (base64-encoded)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS IAM OIDC provider ARN (for the operator IRSA role + the in-cluster ArgoCD Secret annotation)"
  type        = string
}

variable "oidc_issuer" {
  description = "EKS OIDC issuer host without the https:// scheme (oidc.eks.<region>.amazonaws.com/id/<id>)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the cluster lands in"
  type        = string
}

# --- bootstrap behavior -----------------------------------------------------
variable "enable_agent_platform" {
  description = "Label the cluster into the eks-agent-platform operator ApplicationSet so eks-gitops installs the operator via GitOps from the per-cluster OIDC/role annotations. False installs the operator out of band."
  type        = bool
  default     = true
}

variable "tenants_repo_url" {
  description = "SSH URL of the private tenants GitOps repo. When set, the bootstrap registers a read-only deploy key + ArgoCD repo credential so ArgoCD can pull portal-committed tenant manifests. Empty disables it. Requires GITHUB_TOKEN in the environment when set."
  type        = string
  default     = ""
}

variable "gitops_repo_url" {
  description = "GitOps (addon catalog) repository the app-of-apps points at"
  type        = string
  default     = "https://github.com/nanohype/eks-gitops.git"
}

variable "gitops_repo_branch" {
  description = "GitOps repository branch"
  type        = string
  default     = "main"
}

variable "tags" {
  description = "Additional tags merged onto every resource"
  type        = map(string)
  default     = {}
}
