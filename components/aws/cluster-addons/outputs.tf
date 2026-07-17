output "irsa_role_arns" {
  description = "Map of addon IRSA role ARNs"
  value = {
    cert_manager     = module.cert_manager_irsa.iam_role_arn
    external_secrets = module.external_secrets_irsa.iam_role_arn
    alb_controller   = module.alb_controller_irsa.iam_role_arn
    external_dns     = module.external_dns_irsa.iam_role_arn
    loki             = module.loki_irsa.iam_role_arn
    tempo            = module.tempo_irsa.iam_role_arn
    velero           = try(module.velero_irsa[0].iam_role_arn, null)
    opencost         = try(module.opencost_irsa[0].iam_role_arn, null)
    keda             = try(module.keda_irsa[0].iam_role_arn, null)
    argo_events      = try(module.argo_events_irsa[0].iam_role_arn, null)
    argo_workflows   = try(module.argo_workflows_irsa[0].iam_role_arn, null)
  }
}

output "s3_bucket_names" {
  description = "Map of addon S3 bucket names"
  value = {
    loki           = module.loki_bucket.s3_bucket_id
    tempo          = module.tempo_bucket.s3_bucket_id
    velero         = try(module.velero_bucket[0].s3_bucket_id, null)
    argo_workflows = try(module.argo_workflows_bucket[0].s3_bucket_id, null)
  }
}

output "alb_controller_policy_json" {
  description = "Rendered inline IAM policy JSON for the AWS Load Balancer Controller role. Lets tests assert the elbv2.k8s.aws/cluster tag conditions."
  value       = module.alb_controller_irsa.role_policy_json
}

output "argo_events_policy_json" {
  description = "Rendered inline IAM policy JSON for the argo-events role (null when disabled). Lets tests assert the SQS/SNS ARN scoping."
  value       = try(module.argo_events_irsa[0].role_policy_json, null)
}
