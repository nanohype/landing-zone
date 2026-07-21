################################################################################
# SSM Parameters (Bridge to GitOps)
################################################################################

locals {
  ssm_prefix = "/druid/${var.environment}/${var.tenant_id}"
}

resource "aws_ssm_parameter" "aurora_endpoint" {
  name  = "${local.ssm_prefix}/aurora/endpoint"
  type  = "String"
  value = module.aurora.cluster_endpoint

  tags = local.tenant_tags
}

resource "aws_ssm_parameter" "aurora_port" {
  name  = "${local.ssm_prefix}/aurora/port"
  type  = "String"
  value = tostring(module.aurora.cluster_port)

  tags = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_deepstorage" {
  name  = "${local.ssm_prefix}/s3/deepstorage"
  type  = "String"
  value = module.deepstorage_bucket.s3_bucket_id

  tags = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_indexlogs" {
  name  = "${local.ssm_prefix}/s3/indexlogs"
  type  = "String"
  value = module.indexlogs_bucket.s3_bucket_id

  tags = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_msq" {
  name  = "${local.ssm_prefix}/s3/msq"
  type  = "String"
  value = module.msq_bucket.s3_bucket_id

  tags = local.tenant_tags
}

resource "aws_ssm_parameter" "historical_role" {
  name  = "${local.ssm_prefix}/role/historical"
  type  = "String"
  value = module.historical_irsa.iam_role_arn

  tags = local.tenant_tags
}

resource "aws_ssm_parameter" "ingestion_role" {
  name  = "${local.ssm_prefix}/role/ingestion"
  type  = "String"
  value = module.ingestion_irsa.iam_role_arn

  tags = local.tenant_tags
}

resource "aws_ssm_parameter" "query_role" {
  name  = "${local.ssm_prefix}/role/query"
  type  = "String"
  value = module.query_irsa.iam_role_arn

  tags = local.tenant_tags
}

resource "aws_ssm_parameter" "msk_bootstrap" {
  count = var.tenant_config.msk_enabled ? 1 : 0

  name  = "${local.ssm_prefix}/msk/bootstrap"
  type  = "String"
  value = aws_msk_serverless_cluster.this[0].arn

  tags = local.tenant_tags
}
