output "model_bucket_name" {
  description = "S3 bucket name for model artifacts"
  value       = module.model_bucket.s3_bucket_id
}

output "model_bucket_arn" {
  description = "S3 bucket ARN for model artifacts"
  value       = module.model_bucket.s3_bucket_arn
}

output "model_kms_key_arn" {
  description = "KMS key ARN for model encryption"
  value       = aws_kms_key.models.arn
}

output "efs_filesystem_id" {
  description = "EFS filesystem ID for model cache"
  value       = aws_efs_file_system.models.id
}

output "efs_access_point_id" {
  description = "EFS access point ID for model cache"
  value       = aws_efs_access_point.models.id
}

output "sqs_inference_queue_url" {
  description = "SQS inference queue URL"
  value       = aws_sqs_queue.inference.url
}

output "sqs_inference_queue_arn" {
  description = "SQS inference queue ARN"
  value       = aws_sqs_queue.inference.arn
}

output "sqs_inference_dlq_url" {
  description = "SQS inference dead-letter queue URL"
  value       = aws_sqs_queue.inference_dlq.url
}

output "dynamodb_inference_table" {
  description = "DynamoDB inference table name"
  value       = aws_dynamodb_table.inference.name
}

output "ecr_repository_uri" {
  description = "ECR repository URI"
  value       = aws_ecr_repository.this.repository_url
}

output "irsa_inference_server_role_arn" {
  description = "IAM role ARN for inference server IRSA"
  value       = module.inference_server_irsa.iam_role_arn
}

output "irsa_api_gateway_role_arn" {
  description = "IAM role ARN for API gateway IRSA"
  value       = module.api_gateway_irsa.iam_role_arn
}

output "inference_server_policy_json" {
  description = "Rendered inline IAM policy JSON for the inference-server role. Lets tests assert the model-bucket/KMS/EFS scoping."
  value       = module.inference_server_irsa.role_policy_json
}

output "api_gateway_policy_json" {
  description = "Rendered inline IAM policy JSON for the api-gateway role. Lets tests assert the SQS/DynamoDB scoping."
  value       = module.api_gateway_irsa.role_policy_json
}
