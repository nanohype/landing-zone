locals {
  ssm_prefix = "/llm/${var.environment}/${var.tenant_id}"
}

resource "aws_ssm_parameter" "s3_model_bucket" {
  name  = "${local.ssm_prefix}/s3-model-bucket"
  type  = "String"
  value = module.model_bucket.s3_bucket_id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_model_kms_key_arn" {
  name  = "${local.ssm_prefix}/s3-model-kms-key-arn"
  type  = "String"
  value = aws_kms_key.models.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "efs_filesystem_id" {
  name  = "${local.ssm_prefix}/efs-filesystem-id"
  type  = "String"
  value = aws_efs_file_system.models.id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "efs_access_point_id" {
  name  = "${local.ssm_prefix}/efs-access-point-id"
  type  = "String"
  value = aws_efs_access_point.models.id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "efs_security_group_id" {
  name  = "${local.ssm_prefix}/efs-security-group-id"
  type  = "String"
  value = aws_security_group.efs.id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "sqs_inference_queue_url" {
  name  = "${local.ssm_prefix}/sqs-inference-queue-url"
  type  = "String"
  value = aws_sqs_queue.inference.url
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "sqs_inference_queue_arn" {
  name  = "${local.ssm_prefix}/sqs-inference-queue-arn"
  type  = "String"
  value = aws_sqs_queue.inference.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "sqs_inference_dlq_url" {
  name  = "${local.ssm_prefix}/sqs-inference-dlq-url"
  type  = "String"
  value = aws_sqs_queue.inference_dlq.url
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "dynamodb_inference_table" {
  name  = "${local.ssm_prefix}/dynamodb-inference-table"
  type  = "String"
  value = aws_dynamodb_table.inference.name
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "ecr_repository_uri" {
  name  = "${local.ssm_prefix}/ecr-repository-uri"
  type  = "String"
  value = aws_ecr_repository.this.repository_url
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "secrets_hf_token_arn" {
  name  = "${local.ssm_prefix}/secrets-hf-token-arn"
  type  = "String"
  value = var.tenant_config.hf_token_enabled ? aws_secretsmanager_secret.hf_token[0].arn : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "inference_server_role_arn" {
  name  = "${local.ssm_prefix}/inference-server-role-arn"
  type  = "String"
  value = module.inference_server_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "api_gateway_role_arn" {
  name  = "${local.ssm_prefix}/api-gateway-role-arn"
  type  = "String"
  value = module.api_gateway_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "namespace" {
  name  = "${local.ssm_prefix}/namespace"
  type  = "String"
  value = local.namespace
  tags  = local.tenant_tags
}
