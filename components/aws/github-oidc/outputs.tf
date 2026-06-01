output "deploy_role_arn" {
  description = "ARN of the GitHub Actions deploy role. Set as the AWS_ROLE_ARN / E2E_AWS_ROLE_ARN GitHub Actions variable when using the CI path."
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = local.oidc_provider_arn
}
