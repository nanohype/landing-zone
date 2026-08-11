data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  cluster_name = "${var.environment}-${var.cluster_name}"
  account_id   = data.aws_caller_identity.current.account_id
  partition    = data.aws_partition.current.partition

  oidc_issuer = replace(module.eks.cluster_oidc_issuer_url, "https://", "")

  # "" (the unset default, same-account) → null so the role-minting modules attach
  # no boundary. Single conversion point — every module input references this local,
  # never the raw var, or IAM would get a literal empty-string boundary ARN.
  cluster_permissions_boundary = var.cluster_permissions_boundary_arn != "" ? var.cluster_permissions_boundary_arn : null

  tags = merge(var.tags, {
    Component = "cluster"
    Team      = var.team
  })

  # Extra tags the EBS CSI driver stamps on every volume it provisions from a
  # PVC, on top of the ones it writes itself.
  #
  # Such a volume is not in terraform state and carries only what the driver
  # puts on it, so the teardown sweep — which filters on
  # kubernetes.io/cluster/<name> — depends entirely on the driver applying that
  # tag. It does, via --k8s-tag-cluster-id, and `owned` rather than `shared` is
  # its behaviour too: the volume belongs to exactly this cluster and is safe to
  # delete with it, which is the claim the sweep acts on. Subnets carry `shared`
  # (subnet_tags.tf) because a subnet legitimately outlives a cluster.
  #
  # What belongs here is only what the driver would not otherwise write.
  #
  # Hoisted out of the addon's configuration_values so a test can assert it. The
  # module's cluster_addons OUTPUT is unknown at plan time, so an assertion
  # reading it passes whether or not the input is set — which is exactly what the
  # first draft of that test did.
  # No kubernetes.io/* key here. The driver reserves that prefix for the tags it
  # manages itself and refuses to start if one appears in --extra-tags:
  #
  #   failed to create driver: invalid driver options: invalid extra tags:
  #   tag key prefix 'kubernetes.io' is reserved
  #
  # ebs-plugin then CrashLoopBackOffs on every restart, the addon sits in
  # CREATING with an EMPTY health array until terraform's 20m wait expires, and
  # the cluster apply fails with nothing anywhere naming the cause. Observed on
  # three consecutive live runs before the logs were captured.
  #
  # The cluster tag the teardown sweep filters on is still applied — by
  # --k8s-tag-cluster-id, which the EKS addon already passes to this same
  # container, and which exists to stamp kubernetes.io/cluster/<id> = owned on
  # every provisioned volume. So the entry removed here was not merely forbidden,
  # it was a duplicate of a tag the driver was always going to write. Verified by
  # deleting it on a live cluster: both replicas went 6/6 Running with zero
  # restarts and the addon reached ACTIVE.
  ebs_csi_volume_tags = local.tags

  # The amazon-cloudwatch-observability configuration, hoisted out of the addon
  # block so a test can assert on it. enhanced_container_insights and
  # containerLogs are explained at the addon in eks.tf, next to the alarms they
  # serve; this note covers only the third, which is newer and less obvious.
  #
  # applicationSignals OFF — this is what keeps the addon out of DEGRADED.
  #
  # It defaults to ON. Its auto-monitor asks the API server for the
  # `opentelemetry.io` group so it can find OpenTelemetryCollector CRs to
  # annotate for auto-instrumentation. Nothing installs the OpenTelemetry
  # Operator on this cluster — the catalog's otel-agent and otel-gateway are
  # plain collector Deployments — so that group does not exist and never will.
  # The manager blocks ~30s on the discovery before binding its health server on
  # :8081, while the liveness probe is already running (initialDelay 15s, period
  # 20s). It is killed at exit 137, restarts, and blocks again:
  #
  #   W! auto-monitor is disabled due to failures in retrieving server groups:
  #      Get ".../apis/opentelemetry.io/v1alpha1": i/o timeout
  #
  # The agents are unaffected and Container Insights metrics keep flowing, so
  # the alarms stay fed — only CR reconciliation dies. That is why it survived:
  # the addon reports DEGRADED, every metric the platform reads is present, and
  # the failure is a controller nobody queries. `rackctl check` is the only thing
  # that sees it, and installs were being run with --skip-preflight to step over
  # it.
  #
  # Turning off a feature this platform does not use beats pinning back to an
  # older build: Application Signals is CloudWatch's APM, and tracing here goes
  # through the tenant's own OTel collector to Tempo. Nothing would consume it.
  cloudwatch_observability_config = {
    agent = {
      config = {
        logs = {
          metrics_collected = {
            kubernetes = {
              enhanced_container_insights = true
            }
          }
        }
      }
    }
    containerLogs      = { enabled = false }
    applicationSignals = { enabled = false }
  }
}

################################################################################
# KMS Key for EKS Secrets Encryption
################################################################################

module "kms" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.0"

  aliases     = ["eks/${local.cluster_name}"]
  description = "KMS key for EKS secrets encryption"

  key_administrators = [
    "arn:${local.partition}:iam::${local.account_id}:root"
  ]

  key_service_roles_for_autoscaling = [
    "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling",
  ]

  tags = local.tags
}

