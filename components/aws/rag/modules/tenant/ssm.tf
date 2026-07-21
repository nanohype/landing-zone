locals {
  ssm_prefix = "/rag/${var.environment}/${var.tenant_id}"
}

resource "aws_ssm_parameter" "opensearch_endpoint" {
  name  = "${local.ssm_prefix}/opensearch-endpoint"
  type  = "String"
  value = aws_opensearchserverless_collection.vectors.collection_endpoint
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "opensearch_collection_arn" {
  name  = "${local.ssm_prefix}/opensearch-collection-arn"
  type  = "String"
  value = aws_opensearchserverless_collection.vectors.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_documents_bucket" {
  name  = "${local.ssm_prefix}/s3-documents-bucket"
  type  = "String"
  value = module.document_bucket.s3_bucket_id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_documents_kms_key_arn" {
  name  = "${local.ssm_prefix}/s3-documents-kms-key-arn"
  type  = "String"
  value = aws_kms_key.documents.arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "dynamodb_conversations_table" {
  name  = "${local.ssm_prefix}/dynamodb-conversations-table"
  type  = "String"
  value = aws_dynamodb_table.conversations.name
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "bedrock_api_role_arn" {
  name  = "${local.ssm_prefix}/bedrock-api-role-arn"
  type  = "String"
  value = module.bedrock_api_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "namespace" {
  name  = "${local.ssm_prefix}/namespace"
  type  = "String"
  value = local.namespace
  tags  = local.tenant_tags
}
