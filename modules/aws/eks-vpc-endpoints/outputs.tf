output "endpoints" {
  description = "Map of every VPC endpoint created, keyed by endpoint name (s3, ecr_api, ecr_dkr, secretsmanager, ssm, sts, eks_auth, aps_workspaces, and eks when enabled)"
  value       = module.endpoints.endpoints
}
