output "app_access_policy_arn" {
  description = "ARN of the <environment>-<app_name>-app-access managed policy. Reference it from Platform.spec.identity.extraPolicyArns; the operator attaches it to the tenant role."
  value       = aws_iam_policy.app_access.arn
}

output "tenant_role_arn" {
  description = "ARN of the operator-reconciled <environment>-<app_name>-tenant role the app's ServiceAccount is bound to via the Pod Identity association."
  value       = data.aws_iam_role.tenant.arn
}
