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
