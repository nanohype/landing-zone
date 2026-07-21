################################################################################
# SSM Parameters (Bridge to GitOps)
################################################################################

locals {
  ssm_prefix = "/mlops/${var.environment}/${var.tenant_id}"
}

resource "aws_ssm_parameter" "s3_datasets_bucket" {
  name  = "${local.ssm_prefix}/s3-datasets-bucket"
  type  = "String"
  value = module.datasets_bucket.s3_bucket_id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_artifacts_bucket" {
  name  = "${local.ssm_prefix}/s3-artifacts-bucket"
  type  = "String"
  value = module.artifacts_bucket.s3_bucket_id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_kms_key_arn" {
  name  = "${local.ssm_prefix}/s3-kms-key-arn"
  type  = "String"
  value = aws_kms_key.this.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "dynamodb_experiments_table" {
  name  = "${local.ssm_prefix}/dynamodb-experiments-table"
  type  = "String"
  value = aws_dynamodb_table.experiments.name
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "dynamodb_experiments_table_arn" {
  name  = "${local.ssm_prefix}/dynamodb-experiments-table-arn"
  type  = "String"
  value = aws_dynamodb_table.experiments.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "dynamodb_model_registry_table" {
  name  = "${local.ssm_prefix}/dynamodb-model-registry-table"
  type  = "String"
  value = aws_dynamodb_table.model_registry.name
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "dynamodb_model_registry_table_arn" {
  name  = "${local.ssm_prefix}/dynamodb-model-registry-table-arn"
  type  = "String"
  value = aws_dynamodb_table.model_registry.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "sqs_training_queue_url" {
  name  = "${local.ssm_prefix}/sqs-training-queue-url"
  type  = "String"
  value = aws_sqs_queue.training.url
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "sqs_training_queue_arn" {
  name  = "${local.ssm_prefix}/sqs-training-queue-arn"
  type  = "String"
  value = aws_sqs_queue.training.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "sqs_training_dlq_url" {
  name  = "${local.ssm_prefix}/sqs-training-dlq-url"
  type  = "String"
  value = aws_sqs_queue.training_dlq.url
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "sqs_training_dlq_arn" {
  name  = "${local.ssm_prefix}/sqs-training-dlq-arn"
  type  = "String"
  value = aws_sqs_queue.training_dlq.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "ecr_repository_uri" {
  name  = "${local.ssm_prefix}/ecr-repository-uri"
  type  = "String"
  value = var.tenant_config.ecr_enabled ? aws_ecr_repository.this[0].repository_url : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "ecr_repository_arn" {
  name  = "${local.ssm_prefix}/ecr-repository-arn"
  type  = "String"
  value = var.tenant_config.ecr_enabled ? aws_ecr_repository.this[0].arn : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "training_worker_role_arn" {
  name  = "${local.ssm_prefix}/training-worker-role-arn"
  type  = "String"
  value = module.training_worker_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "model_registry_role_arn" {
  name  = "${local.ssm_prefix}/model-registry-role-arn"
  type  = "String"
  value = module.model_registry_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "mlops_api_role_arn" {
  name  = "${local.ssm_prefix}/mlops-api-role-arn"
  type  = "String"
  value = module.mlops_api_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "namespace" {
  name  = "${local.ssm_prefix}/namespace"
  type  = "String"
  value = local.namespace
  tags  = local.tenant_tags
}
