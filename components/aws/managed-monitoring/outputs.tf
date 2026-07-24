################################################################################
# Outputs to wire into eks-gitops:
#   - addons-otel-gateway appset: amp_remote_write_url + region for the gateway
#   - dashboards/base: grafana_endpoint
################################################################################

output "amp_workspace_id" {
  description = "AMP workspace ID"
  value       = aws_prometheus_workspace.this.id
}

output "amp_workspace_arn" {
  description = "AMP workspace ARN"
  value       = aws_prometheus_workspace.this.arn
}

output "amp_remote_write_url" {
  description = "AMP remote-write endpoint (injected into the eks-gitops otel-gateway addon)"
  value       = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
}

output "amp_query_endpoint" {
  description = "AMP query endpoint (used as Grafana Prometheus data source URL)"
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}

output "otel_gateway_amp_role_arn" {
  description = "Pod Identity role ARN bound to the otel-gateway service account (monitoring/otel-gateway) for AMP remote_write"
  value       = module.otel_gateway_amp.iam_role_arn
}

output "grafana_endpoint" {
  description = "Grafana workspace endpoint URL"
  value       = "https://${aws_grafana_workspace.this.endpoint}"
}

output "grafana_workspace_id" {
  description = "Grafana workspace ID"
  value       = aws_grafana_workspace.this.id
}

output "grafana_workspace_arn" {
  description = "Grafana workspace ARN"
  value       = aws_grafana_workspace.this.arn
}

output "monitoring_endpoints_secret_name" {
  description = "Secrets Manager secret holding the AMP query + remote-write URLs (synced into the cluster by External Secrets Operator)"
  value       = aws_secretsmanager_secret.monitoring_endpoints.name
}

output "grafana_url_ssm_parameter" {
  description = "SSM parameter holding the AMG workspace URL (read by cluster-bootstrap to annotate the ArgoCD cluster Secret)"
  value       = aws_ssm_parameter.grafana_url.name
}

output "grafana_token_secret_name" {
  description = "Secrets Manager secret holding the AMG service-account token (+ the workspace/service-account ids the rotator needs). Consumed by the catalog's grafana-external-credentials ExternalSecret."
  value       = aws_secretsmanager_secret.grafana_token.name
}

output "grafana_token_rotator_role_arn" {
  description = "Pod Identity role for the grafana-token-rotator CronJob."
  value       = module.grafana_token_rotator_irsa.iam_role_arn
}
