output "datasets_bucket_name" {
  description = "Datasets S3 bucket name"
  value       = module.datasets_bucket.s3_bucket_id
}

output "datasets_bucket_arn" {
  description = "Datasets S3 bucket ARN"
  value       = module.datasets_bucket.s3_bucket_arn
}

output "artifacts_bucket_name" {
  description = "Artifacts S3 bucket name"
  value       = module.artifacts_bucket.s3_bucket_id
}

output "artifacts_bucket_arn" {
  description = "Artifacts S3 bucket ARN"
  value       = module.artifacts_bucket.s3_bucket_arn
}

output "kms_key_arn" {
  description = "KMS key ARN for MLOps encryption"
  value       = aws_kms_key.this.arn
}

output "experiments_table_name" {
  description = "Experiments DynamoDB table name"
  value       = aws_dynamodb_table.experiments.name
}

output "experiments_table_arn" {
  description = "Experiments DynamoDB table ARN"
  value       = aws_dynamodb_table.experiments.arn
}

output "model_registry_table_name" {
  description = "Model registry DynamoDB table name"
  value       = aws_dynamodb_table.model_registry.name
}

output "model_registry_table_arn" {
  description = "Model registry DynamoDB table ARN"
  value       = aws_dynamodb_table.model_registry.arn
}

output "training_queue_url" {
  description = "Training SQS queue URL"
  value       = aws_sqs_queue.training.url
}

output "training_queue_arn" {
  description = "Training SQS queue ARN"
  value       = aws_sqs_queue.training.arn
}

output "training_dlq_url" {
  description = "Training dead-letter queue URL"
  value       = aws_sqs_queue.training_dlq.url
}

output "training_dlq_arn" {
  description = "Training dead-letter queue ARN"
  value       = aws_sqs_queue.training_dlq.arn
}

output "ecr_repository_uri" {
  description = "ECR repository URI (null if disabled)"
  value       = var.tenant_config.ecr_enabled ? aws_ecr_repository.this[0].repository_url : null
}

output "ecr_repository_arn" {
  description = "ECR repository ARN (null if disabled)"
  value       = var.tenant_config.ecr_enabled ? aws_ecr_repository.this[0].arn : null
}

output "training_worker_role_arn" {
  description = "Pod Identity role ARN for the training-worker service account"
  value       = module.training_worker_irsa.iam_role_arn
}

output "model_registry_role_arn" {
  description = "Pod Identity role ARN for the model-registry service account"
  value       = module.model_registry_irsa.iam_role_arn
}

output "mlops_api_role_arn" {
  description = "Pod Identity role ARN for the mlops-api service account"
  value       = module.mlops_api_irsa.iam_role_arn
}

output "namespace" {
  description = "Kubernetes namespace for this tenant's MLOps workloads"
  value       = local.namespace
}

output "training_worker_policy_json" {
  description = "Rendered inline IAM policy JSON for the training-worker role. Lets tests assert the S3/KMS/DynamoDB/SQS scoping."
  value       = module.training_worker_irsa.role_policy_json
}

output "model_registry_policy_json" {
  description = "Rendered inline IAM policy JSON for the model-registry role. Lets tests assert the DynamoDB/S3 scoping."
  value       = module.model_registry_irsa.role_policy_json
}

output "mlops_api_policy_json" {
  description = "Rendered inline IAM policy JSON for the mlops-api role. Lets tests assert the read-scoped grants."
  value       = module.mlops_api_irsa.role_policy_json
}
