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

# Uniform envcommon interface variable — every component declares it for live/_envcommon wiring; not consumed here.
# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region"
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster base name (prefixed with environment)"
  type        = string
  default     = "platform"

  validation {
    condition     = length(var.cluster_name) <= 12
    error_message = "cluster_name (the base token) must be <= 12 chars. The derived <environment>-<cluster_name> feeds cluster-scoped S3/IAM names; the tightest budget is agent-iam's account+region-qualified model-artifacts bucket (<cluster>-<account>-<region>-model-artifacts), which leaves 12 chars for the base in us-west-2 (fewer in a longer region — caught by the bucket precondition)."
  }
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.36"

  # EKS takes the control-plane version as major.minor only ("1.36", not "1.36.2"
  # or "v1.36"). Reject the common malformed shapes at plan time rather than
  # letting the module surface a late, opaque API error.
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.cluster_version))
    error_message = "cluster_version must be Kubernetes major.minor, e.g. \"1.36\" (no patch component, no leading \"v\")."
  }
}

variable "eks_addon_versions" {
  description = <<-EOT
    Pinned EKS managed add-on versions, keyed by addon name (vpc-cni, coredns,
    kube-proxy, aws-ebs-csi-driver, eks-pod-identity-agent). Pinning makes the
    addon set reproducible instead of rolling to most_recent on every apply. The
    defaults are the EKS-default versions for the default cluster_version (1.36);
    RE-PIN THEM WHEN cluster_version CHANGES. Source current values with:
      aws eks describe-addon-versions --kubernetes-version <ver> \
        --query 'addons[].{n:addonName,v:addonVersions[?compatibilities[?defaultVersion==`true`]].addonVersion|[0]}'
    An addon omitted from this map falls back to most_recent for that addon only.
  EOT
  type        = map(string)
  default = {
    vpc-cni                = "v1.21.2-eksbuild.2"
    coredns                = "v1.14.2-eksbuild.4"
    kube-proxy             = "v1.36.0-eksbuild.7"
    aws-ebs-csi-driver     = "v1.62.0-eksbuild.1"
    eks-pod-identity-agent = "v1.3.10-eksbuild.3"
  }
}

# Network inputs (from network component)
variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS nodes"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for load balancers"
  type        = list(string)
}

variable "stamp_subnet_tags" {
  description = <<-EOT
    Stamp this cluster's kubernetes.io/cluster/<cluster>=shared ownership tag onto the
    shared subnets (aws_ec2_tag). true (default) when the cluster owns or shares an
    in-account VPC. Set false when the cluster adopts a VPC it does not own (a
    cross-account VPC shared over RAM): a participant cannot tag a foreign-owned
    subnet, so the network owner (shared-network) owns subnet tagging in that topology.
  EOT
  type        = bool
  default     = true
}

# Cluster access
variable "cluster_endpoint_public_access" {
  description = "Enable public API endpoint — explicit opt-in; private by default (requires VPC endpoints for eks and eks-auth when false)"
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public EKS API endpoint. Required (non-empty) whenever cluster_endpoint_public_access is true — there is no 0.0.0.0/0 fallback. Set to your operator IP(s)."
  type        = list(string)
  default     = []

  # Secure-by-default: a public API endpoint with no allow-list is world-reachable. Reject
  # that combination at plan time rather than silently opening it to 0.0.0.0/0. (Empty is fine
  # when public access is off — the CIDRs are then unused.)
  validation {
    condition     = !var.cluster_endpoint_public_access || length(var.cluster_endpoint_public_access_cidrs) > 0
    error_message = "cluster_endpoint_public_access_cidrs must be a non-empty allow-list when cluster_endpoint_public_access is true (no 0.0.0.0/0 default)."
  }
}

variable "access_entries" {
  description = <<-EOT
    Extra EKS access entries for IAM principals, keyed by name. The principal
    that applies this component is already granted cluster-admin via
    enable_cluster_creator_admin_permissions, so this defaults to empty;
    populate it per-environment with real principal ARNs (CI roles, SSO admin
    roles, etc.). Do NOT put placeholder ARNs here — an invalid principal_arn
    fails the apply.
  EOT
  type        = any
  default     = {}
}

# System node group
variable "system_node_instance_types" {
  description = "Instance types for system node group (Graviton/arm64 — pair with the ARM_64 AMI)"
  type        = list(string)
  default     = ["m7g.xlarge", "m6g.xlarge"]
}

variable "system_node_min_size" {
  description = "Minimum number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_max_size" {
  description = "Maximum number of system nodes"
  type        = number
  default     = 6
}

variable "system_node_desired_size" {
  description = "Desired number of system nodes"
  type        = number
  default     = 2
}

variable "system_node_disk_size" {
  description = <<-EOT
    Size in GB of the Bottlerocket DATA volume (/dev/xvdb) on system nodes — where
    container images and ephemeral storage live. NOT the OS volume (/dev/xvda), which
    is read-only and stays at the AMI's 2 GiB.

    The default must comfortably hold the whole addon catalog's image set. The AMI's
    own default is 20 GiB, which does not: a fresh install pulled itself into
    DiskPressure and the kubelet evicted 30 pods mid-convergence.
  EOT
  type        = number
  default     = 100

  validation {
    # 20 GiB is the AMI default that caused the eviction storm; anything at or below it
    # reproduces the bug this variable exists to prevent.
    condition     = var.system_node_disk_size >= 50
    error_message = "system_node_disk_size must be at least 50 GB — the platform's addon image set does not fit in less, and the nodes hit DiskPressure while still converging."
  }
}

variable "team" {
  description = "Owning team for this component"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}

# --- cross-account vending (eks-fleet rung 2) -------------------------------
# When this cluster is vended into a workload account, the management hub assumes
# that account's fleet-vend role to provision it. fleet-vend double-locks
# iam:CreateRole (and CreatePolicy): every IAM role + the encryption policy this
# component mints must land under the /eks-fleet/ path AND every role must carry
# the vend boundary (iam:PermissionsBoundary condition). Defaults "/" + empty =
# unchanged behavior outside the fleet gate.
variable "cluster_iam_role_path" {
  description = "IAM path for every IAM role + managed policy the cluster mints (cluster role, system node-group role, Karpenter controller/node roles, IRSA roles, encryption policy). Set to \"/eks-fleet/\" for cross-account fleet-vend gating; \"/\" (default) = root path = unchanged same-account behavior."
  type        = string
  default     = "/"
}

variable "cluster_permissions_boundary_arn" {
  description = "Permissions-boundary ARN attached to every IAM role the cluster mints. Fleet vends MUST set it to the vend/hub boundary ARN — the fleet roles' CreateRole gate rejects any role that doesn't carry their ceiling. Empty (default) = no boundary (running outside the fleet gate)."
  type        = string
  default     = ""
}
