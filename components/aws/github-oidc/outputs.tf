output "deploy_role_arn" {
  description = "ARN of the GitHub Actions deploy role. Set it as DEPLOY_ROLE_ARN on the GitHub Environment deploy.yml and destroy.yml declare (see docs/operations.md) and as E2E_AWS_ROLE_ARN for e2e.yml when using the CI path. Never the repository-level AWS_ROLE_ARN: that holds plan_role_arn, and this role does not trust the plan environment ci.yml's plan job and drift.yml run in. Null when create_deploy_role is false."
  value       = var.create_deploy_role ? aws_iam_role.deploy[0].arn : null
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider"
  value       = local.oidc_provider_arn
}

output "plan_role_arn" {
  description = "ARN of the read-only GitHub Actions plan role. Set as the AWS_ROLE_ARN repo variable so the CI plan matrix can assume it, and as this account's entry in the DRIFT_PLAN_ROLE_ARNS repo variable so drift.yml can plan the account's production and staging leaves. Null when create_plan_role is false."
  value       = var.create_plan_role ? aws_iam_role.plan[0].arn : null
}

output "ecr_public_pull_role_arn" {
  description = "ARN of the GitHub Actions ECR Public pull role. Set as the repo variable the pulling workflows read the role from. Null when create_ecr_public_pull_role is false."
  value       = var.create_ecr_public_pull_role ? aws_iam_role.ecr_public_pull[0].arn : null
}
