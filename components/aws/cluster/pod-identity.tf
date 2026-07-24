################################################################################
# Pod Identity Roles for All Platform Addons
################################################################################

locals {
  # Key on the full cluster name (<environment>-<clusterName>), not the environment,
  # so this cluster's addon roles don't collide with a co-located sibling in the
  # same account and environment.
  role_name_prefix = local.cluster_name
}

# EBS CSI Driver
module "ebs_csi_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name = "${local.role_name_prefix}-ebs-csi"
  # module.eks.cluster_name, not the local string: the Pod Identity association
  # this module creates must be ordered AFTER the cluster exists (like karpenter's),
  # or tofu attempts CreatePodIdentityAssociation before the cluster is up — it
  # never lands, the ebs-csi controller never gets creds, and the addon-wait
  # deadlocks. Same value, load-bearing dependency.
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"

  managed_policy_arns = [
    "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy",
  ]

  # cross-account fleet-vend gating: the role sits under the fleet path
  path                 = var.cluster_iam_role_path
  permissions_boundary = local.cluster_permissions_boundary

  tags = local.tags
}

# CloudWatch Observability agent (Container Insights)
#
# The amazon-cloudwatch-observability addon runs its agent as the
# `cloudwatch-agent` service account in the `amazon-cloudwatch` namespace. The
# addon resource carries the association inline, but the role is minted here so
# it lives with the other addon roles and inherits the same path and boundary —
# on a fleet-vended cluster both are load-bearing.
module "cloudwatch_observability" {
  source = "../../../modules/aws/workload-identity"

  role_name = "${local.role_name_prefix}-cloudwatch-agent"
  # module.eks.cluster_name for the same ordering reason the EBS CSI role uses
  # it: the association cannot be created before the cluster exists.
  cluster_name    = module.eks.cluster_name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"

  # The AWS-managed policy for the CloudWatch agent — PutMetricData, the EMF log
  # path, and the EC2/EKS describes it uses to resolve node identity. Attaching
  # the managed policy rather than transcribing it means AWS carries the drift
  # when the agent grows a call, which is the whole point of a managed addon.
  managed_policy_arns = [
    "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy",
  ]

  path                 = var.cluster_iam_role_path
  permissions_boundary = local.cluster_permissions_boundary

  tags = local.tags
}

# OpenTelemetry gateway, floor tier
#
# A floor cluster's collector gateway exports metrics as CloudWatch EMF and logs
# to CloudWatch Logs — both of which are CloudWatch Logs writes, since EMF is
# structured log records CloudWatch extracts metrics from.
#
# Bound to `otel-gateway-cw`, NOT `otel-gateway`. EKS permits one Pod Identity
# association per (namespace, service account), and managed-monitoring already
# binds (monitoring, otel-gateway) to the AMP remote-write role on every cluster
# that runs it. Two roles cannot share the identity, so the floor tier's gateway
# runs as a differently-named service account.
#
# Minted unconditionally rather than behind a tier flag. On a full cluster the
# service account simply does not exist and the association sits unused, which
# costs nothing — and it means flipping a cluster between tiers is a label
# change in one repo, not a coordinated terraform apply.
module "otel_gateway_cloudwatch" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.role_name_prefix}-otel-gateway-cw"
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "otel-gateway-cw"

  # Scoped to the log groups the gateway's own exporters write, rather than the
  # blanket CloudWatchAgentServerPolicy: this workload carries tenant telemetry,
  # so its credential should not also be able to publish arbitrary custom
  # metrics or read the account's other log groups.
  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents",
        "logs:PutRetentionPolicy",
      ]
      Resource = [
        "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/aws/otel/${local.cluster_name}*",
      ]
    },
  ]

  path                 = var.cluster_iam_role_path
  permissions_boundary = local.cluster_permissions_boundary

  tags = local.tags
}
