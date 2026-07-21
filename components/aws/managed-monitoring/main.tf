locals {
  # Key on the full cluster name (<environment>-<clusterName>) so the addon roles match
  # this cluster's AMP/AMG resources (which already key on var.cluster_name) and don't
  # collide with a co-located sibling cluster in the same account and environment.
  role_name_prefix = var.cluster_name

  tags = merge(var.tags, {
    Component = "managed-monitoring"
    Team      = var.team
  })
}

################################################################################
# Amazon Managed Service for Prometheus (AMP) workspace
################################################################################

resource "aws_prometheus_workspace" "this" {
  alias = "${var.cluster_name}-amp"

  tags = local.tags
}

resource "aws_prometheus_alert_manager_definition" "this" {
  count        = var.amp_alert_rules_enabled ? 1 : 0
  workspace_id = aws_prometheus_workspace.this.id

  definition = <<-EOT
    alertmanager_config: |
      route:
        receiver: default
        group_by: [alertname, cluster]
      receivers:
        - name: default
  EOT
}

################################################################################
# Pod Identity — alloy remote-write into AMP
#
# Allows the in-cluster alloy collector (DaemonSet, service account `alloy` in
# the `monitoring` namespace) to push metrics to AMP via SigV4. The workload is
# alloy — Grafana's successor to the grafana-agent — so the identity is bound to
# the `alloy` service account. Binding it to the old `grafana-agent` name would
# leave the real workload falling back to the node instance role, which has no
# aps:RemoteWrite and gets a 403 on every remote_write batch.
################################################################################

module "alloy_amp_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.role_name_prefix}-alloy-amp"
  cluster_name    = var.cluster_name
  namespace       = "monitoring"
  service_account = "alloy"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "aps:RemoteWrite",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata",
      ]
      Resource = [aws_prometheus_workspace.this.arn]
    },
  ]

  tags = local.tags
}

################################################################################
# Amazon Managed Grafana (AMG) workspace
################################################################################

resource "aws_iam_role" "grafana_workspace" {
  name = "${var.cluster_name}-amg-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "grafana_workspace_amp" {
  name = "amp-data-source"
  role = aws_iam_role.grafana_workspace.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:ListWorkspaces",
        "aps:DescribeWorkspace",
        "aps:QueryMetrics",
        "aps:GetLabels",
        "aps:GetSeries",
        "aps:GetMetricMetadata",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy" "grafana_workspace_cloudwatch" {
  name = "cloudwatch-data-source"
  role = aws_iam_role.grafana_workspace.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:DescribeAlarmsForMetric",
        "cloudwatch:DescribeAlarmHistory",
        "cloudwatch:DescribeAlarms",
        "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetInsightRuleReport",
        "logs:DescribeLogGroups",
        "logs:GetLogGroupFields",
        "logs:StartQuery",
        "logs:StopQuery",
        "logs:GetQueryResults",
        "logs:GetLogEvents",
        "ec2:DescribeTags",
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_grafana_workspace" "this" {
  name                     = "${var.cluster_name}-amg"
  account_access_type      = var.amg_account_access_type
  authentication_providers = var.amg_authentication_providers
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana_workspace.arn

  data_sources = ["PROMETHEUS", "CLOUDWATCH"]

  tags = local.tags
}

################################################################################
# AMG role assignments — humans
################################################################################

resource "aws_grafana_role_association" "admin" {
  count = length(var.amg_admin_user_ids) > 0 ? 1 : 0

  role         = "ADMIN"
  user_ids     = var.amg_admin_user_ids
  workspace_id = aws_grafana_workspace.this.id
}

resource "aws_grafana_role_association" "editor" {
  count = length(var.amg_editor_user_ids) > 0 ? 1 : 0

  role         = "EDITOR"
  user_ids     = var.amg_editor_user_ids
  workspace_id = aws_grafana_workspace.this.id
}

resource "aws_grafana_role_association" "viewer" {
  count = length(var.amg_viewer_user_ids) > 0 ? 1 : 0

  role         = "VIEWER"
  user_ids     = var.amg_viewer_user_ids
  workspace_id = aws_grafana_workspace.this.id
}

################################################################################
# Endpoint wiring — make the per-environment AMP/AMG endpoints available to the
# in-cluster consumers without hand-edited placeholders.
#
#   - AMP query + remote-write URLs go to Secrets Manager. External Secrets
#     Operator syncs them into the cluster (the aws-secrets-manager
#     ClusterSecretStore), where the Grafana data source templates its url from
#     the synced Secret and alloy reads its remote-write url from an env
#     var. The endpoints aren't sensitive; Secrets Manager is simply the store
#     ESO is wired to, alongside the Grafana service-account token.
#   - The AMG workspace URL goes to SSM. The Grafana CR's url field can't be
#     templated from a Secret, so cluster-bootstrap reads it from here and stamps
#     it onto the ArgoCD cluster Secret, where the dashboards ApplicationSet
#     injects it into the Grafana CR via the cluster generator.
################################################################################

resource "aws_secretsmanager_secret" "monitoring_endpoints" {
  # Cluster-scoped so co-located sibling clusters in one account+region don't
  # collide on the Secrets Manager name. The eks-gitops ExternalSecret readers
  # patch remoteRef.key to this same <cluster_name>-… per cluster.
  name = "${var.cluster_name}-managed-monitoring-endpoints"
  # Endpoints, not credentials — drop the recovery window so a teardown/recreate
  # cycle doesn't collide with a soft-deleted secret of the same name.
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "monitoring_endpoints" {
  secret_id = aws_secretsmanager_secret.monitoring_endpoints.id
  secret_string = jsonencode({
    AMP_QUERY_URL        = aws_prometheus_workspace.this.prometheus_endpoint
    AMP_REMOTE_WRITE_URL = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
  })
}

resource "aws_ssm_parameter" "grafana_url" {
  name  = "/eks-agent-platform/${var.cluster_name}/managed-monitoring/grafana_url"
  type  = "String"
  value = "https://${aws_grafana_workspace.this.endpoint}"

  tags = local.tags
}

# AMP (Amazon Managed Prometheus) query endpoint — consumed by opencost via a
# sigv4 proxy (cluster-bootstrap stamps it onto the cluster Secret annotation
# monitoring/amp-endpoint, the opencost ApplicationSet reads it). Same
# publish-to-SSM pattern as grafana_url so the value never lands in gitops.
resource "aws_ssm_parameter" "amp_endpoint" {
  name  = "/eks-agent-platform/${var.cluster_name}/managed-monitoring/amp_endpoint"
  type  = "String"
  value = aws_prometheus_workspace.this.prometheus_endpoint

  tags = local.tags
}

# AMP workspace id — the opencost chart's native AMP integration keys on the
# workspace id (opencost.prometheus.amp.workspaceId), not the full URL.
resource "aws_ssm_parameter" "amp_workspace_id" {
  name  = "/eks-agent-platform/${var.cluster_name}/managed-monitoring/amp_workspace_id"
  type  = "String"
  value = aws_prometheus_workspace.this.id

  tags = local.tags
}

################################################################################
# The Grafana service account, its token, and the rotation that keeps it alive
#
# grafana-operator pushes every dashboard, data source and alert rule into the
# AMG workspace using a bearer token it reads from a Secret. The catalog's
# ExternalSecret sources that token from a Secrets Manager secret named
# `<cluster_name>-grafana-token` (cluster-scoped), and nothing else creates it —
# so terraform seeds it here. Without the seed, day 0 needs a human in the loop
# and the dashboards app ships broken on every fresh install.
#
# There is no long-lived credential to reach for. AMG caps a service-account
# token at 30 days (CreateWorkspaceServiceAccountToken rejects secondsToLive >
# 2592000), and grafana-operator's `external` Grafana CR speaks only a bearer
# apiKey — it has no SigV4/IAM path. So the token MUST be rotated by something,
# and a hand-made one is a 30-day fuse under every cluster we vend.
#
# Two halves, and both are needed:
#
#   - Terraform seeds the first token here, so day 0 is green with no manual
#     step. It also re-seeds on any apply, which is what recovers a cluster that
#     sat dead longer than the token's life.
#   - The grafana-token-rotator CronJob in the gitops catalog replaces it weekly
#     thereafter, using the Pod Identity granted below.
#
# The secret carries its own config (workspaceId, serviceAccountId, region)
# alongside the token. That is what lets the rotator run with no ApplicationSet
# templating and no new cluster-Secret annotations — it reads everything it
# needs from the one secret it is already required to read.
################################################################################

# ADMIN, not EDITOR: grafana-operator reconciles GrafanaDatasource and
# GrafanaAlertRuleGroup CRs, and Grafana gates data-source and alerting
# provisioning behind admin. The scope is the workspace, nothing else.
resource "aws_grafana_workspace_service_account" "dashboards" {
  name         = "grafana-operator"
  grafana_role = "ADMIN"
  workspace_id = aws_grafana_workspace.this.id
}

resource "aws_grafana_workspace_service_account_token" "bootstrap" {
  name               = "terraform-bootstrap"
  service_account_id = aws_grafana_workspace_service_account.dashboards.service_account_id
  seconds_to_live    = 2592000 # 30 days — the AMG maximum
  workspace_id       = aws_grafana_workspace.this.id
}

resource "aws_secretsmanager_secret" "grafana_token" {
  # Cluster-scoped (see monitoring_endpoints above) — the dashboards ExternalSecret
  # + rotator CronJob patch this same <cluster_name>-grafana-token per cluster.
  name = "${var.cluster_name}-grafana-token"
  # The rotator replaces this value in place. Drop the recovery window so a
  # teardown/recreate cycle doesn't collide with a soft-deleted secret of the
  # same name — same reasoning as monitoring_endpoints above.
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "grafana_token" {
  secret_id = aws_secretsmanager_secret.grafana_token.id
  secret_string = jsonencode({
    token            = aws_grafana_workspace_service_account_token.bootstrap.key
    workspaceId      = aws_grafana_workspace.this.id
    serviceAccountId = aws_grafana_workspace_service_account.dashboards.service_account_id
    region           = var.region
  })

  # The CronJob owns this value once it has run. Without ignore_changes, every
  # subsequent apply would stomp the live token back to the bootstrap one in
  # Terraform's state — which, more than 30 days after the install, has expired.
  # The apply would report success and the dashboards would go dark.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# The rotator needs exactly three things: mint a token, list and delete the old
# ones (AMG caps tokens per service account, so they must not accumulate), and
# write the result back to the single secret it owns.
module "grafana_token_rotator_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.role_name_prefix}-grafana-token-rotator"
  cluster_name    = var.cluster_name
  namespace       = "grafana-operator"
  service_account = "grafana-token-rotator"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "grafana:CreateWorkspaceServiceAccountToken",
        "grafana:ListWorkspaceServiceAccountTokens",
        "grafana:DeleteWorkspaceServiceAccountToken",
      ]
      Resource = [aws_grafana_workspace.this.arn]
    },
    {
      Effect = "Allow"
      Action = [
        "secretsmanager:PutSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = [aws_secretsmanager_secret.grafana_token.arn]
    },
  ]

  tags = local.tags
}
