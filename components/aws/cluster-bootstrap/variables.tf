variable "environment" {
  description = "Environment name (development, staging, production)"
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

variable "cilium_version" {
  description = "Cilium Helm chart version"
  type        = string
  default     = "1.19.5"
}

variable "cilium_operator_replicas" {
  description = "Number of Cilium operator replicas"
  type        = number
  default     = 2
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "10.1.3"
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

# NO DEFAULT, deliberately. This must be the operator's OWN fork of the addon
# catalog. It previously defaulted to https://github.com/nanohype/eks-gitops.git,
# and because nothing in live/ passed a value, every install silently synced its
# app-of-apps from nanohype's main branch — an upstream commit landed straight on
# a downstream cluster, unpinned, and the org's own fork sat unused. A missing
# value must fail the plan, loudly, rather than fall back to someone else's repo.
variable "gitops_repo_url" {
  description = "GitOps (addon catalog) repository the app-of-apps points at. MUST be this org's own fork — no default; omitting it is an error."
  type        = string

  validation {
    condition     = can(regex("^(https://|git@)", var.gitops_repo_url))
    error_message = "gitops_repo_url must be a git URL (https:// or git@)."
  }
}

variable "gitops_repo_branch" {
  description = "GitOps repository branch"
  type        = string
  default     = "main"
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

variable "enable_managed_monitoring" {
  description = "Stamp the Amazon Managed Grafana workspace URL (read from the SSM parameter the managed-monitoring component writes under /eks-agent-platform/<cluster-name>/managed-monitoring/) onto the cluster Secret, where the dashboards ApplicationSet injects it into the Grafana CR. Opt-in (default false), mirroring enable_eval_runtime: set true only on a cluster whose managed-monitoring component has already applied and published the parameter — a default-true fails the SSM read on any cluster that doesn't run managed-monitoring. Left false, the dashboards Grafana CR renders without an external URL."
  type        = bool
  default     = false
}

variable "enable_accelerators" {
  description = "Label this cluster eks-agent-platform/accelerators=true so the accelerators ApplicationSet (gpu-operator, nvidia-dra-driver) targets it. Opt-in (default false) so non-GPU shapes skip GPU addons entirely — a GPU driver on a cluster with no GPU nodes can't pull (nvcr.io needs an NGC key) and has nothing to schedule on."
  type        = bool
  default     = false
}

variable "enable_eval_runtime" {
  description = "Republish the eval-runner IRSA wiring (role ARN + reports bucket) as cluster-Secret annotations, read from the SSM parameters the eks-agent-platform eval-runtime component writes under /eks-agent-platform/<env>/eval-runtime/. Requires that component to have applied first. Default false; the eks-gitops operator ApplicationSet tolerates the annotations being absent (eval simply gets no IRSA), so leave it off on clusters without eval-runtime."
  type        = bool
  default     = false
}
