output "deploy_role_arn" {
  description = "ARN of the GitHub Actions deploy role. Set as the AWS_ROLE_ARN / E2E_AWS_ROLE_ARN GitHub Actions variable when using the CI path."
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = local.oidc_provider_arn
}

output "plan_role_arn" {
  description = "ARN of the read-only GitHub Actions plan role. Set as the AWS_ROLE_ARN repo variable so the CI plan matrix can assume it. Null when create_plan_role is false."
  value       = var.create_plan_role ? aws_iam_role.plan[0].arn : null
}
