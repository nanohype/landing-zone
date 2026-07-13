data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  partition        = data.aws_partition.current.partition
  irsa_role_prefix = "${var.environment}-eks"

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
# IRSA — grafana-agent remote-write into AMP
#
# Allows the in-cluster grafana-agent to push metrics to AMP via SigV4.
################################################################################

module "grafana_agent_amp_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_role_prefix}-grafana-agent-amp"
  cluster_name    = var.cluster_name
  namespace       = "monitoring"
  service_account = "grafana-agent"

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
#     the synced Secret and grafana-agent reads its remote-write url from an env
#     var. The endpoints aren't sensitive; Secrets Manager is simply the store
#     ESO is wired to, alongside the Grafana service-account token.
#   - The AMG workspace URL goes to SSM. The Grafana CR's url field can't be
#     templated from a Secret, so cluster-bootstrap reads it from here and stamps
#     it onto the ArgoCD cluster Secret, where the dashboards ApplicationSet
#     injects it into the Grafana CR via the cluster generator.
################################################################################

resource "aws_secretsmanager_secret" "monitoring_endpoints" {
  name = "eks-managed-monitoring-endpoints"
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
  name  = "/eks-agent-platform/${var.environment}/managed-monitoring/grafana_url"
  type  = "String"
  value = "https://${aws_grafana_workspace.this.endpoint}"

  tags = local.tags
}

# AMP (Amazon Managed Prometheus) query endpoint — consumed by opencost via a
# sigv4 proxy (cluster-bootstrap stamps it onto the cluster Secret annotation
# monitoring/amp-endpoint, the opencost ApplicationSet reads it). Same
# publish-to-SSM pattern as grafana_url so the value never lands in gitops.
resource "aws_ssm_parameter" "amp_endpoint" {
  name  = "/eks-agent-platform/${var.environment}/managed-monitoring/amp_endpoint"
  type  = "String"
  value = aws_prometheus_workspace.this.prometheus_endpoint

  tags = local.tags
}

# AMP workspace id — the opencost chart's native AMP integration keys on the
# workspace id (opencost.prometheus.amp.workspaceId), not the full URL.
resource "aws_ssm_parameter" "amp_workspace_id" {
  name  = "/eks-agent-platform/${var.environment}/managed-monitoring/amp_workspace_id"
  type  = "String"
  value = aws_prometheus_workspace.this.id

  tags = local.tags
}
