################################################################################
# SSM Parameters (Bridge to GitOps)
################################################################################

locals {
  ssm_prefix = "/pipeline/${var.environment}/${var.tenant_id}"
}

# S3 Buckets
resource "aws_ssm_parameter" "s3_raw_bucket" {
  name  = "${local.ssm_prefix}/s3-raw-bucket"
  type  = "String"
  value = module.raw_bucket.s3_bucket_id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_staging_bucket" {
  name  = "${local.ssm_prefix}/s3-staging-bucket"
  type  = "String"
  value = module.staging_bucket.s3_bucket_id
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "s3_curated_bucket" {
  name  = "${local.ssm_prefix}/s3-curated-bucket"
  type  = "String"
  value = module.curated_bucket.s3_bucket_id
  tags  = local.tenant_tags
}

# KMS
resource "aws_ssm_parameter" "s3_datalake_kms_key_arn" {
  name  = "${local.ssm_prefix}/s3-datalake-kms-key-arn"
  type  = "String"
  value = aws_kms_key.datalake.arn
  tags  = local.tenant_tags
}

# MSK
resource "aws_ssm_parameter" "msk_cluster_arn" {
  name  = "${local.ssm_prefix}/msk-cluster-arn"
  type  = "String"
  value = var.tenant_config.msk_enabled ? aws_msk_serverless_cluster.this[0].arn : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "msk_bootstrap_brokers" {
  name  = "${local.ssm_prefix}/msk-bootstrap-brokers"
  type  = "String"
  value = var.tenant_config.msk_enabled ? "resolve-post-deploy" : "disabled"
  tags  = local.tenant_tags
}

# Batch
resource "aws_ssm_parameter" "batch_compute_env_arn" {
  name  = "${local.ssm_prefix}/batch-compute-env-arn"
  type  = "String"
  value = var.tenant_config.batch_enabled ? aws_batch_compute_environment.this[0].arn : "disabled"
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "batch_job_queue_arn" {
  name  = "${local.ssm_prefix}/batch-job-queue-arn"
  type  = "String"
  value = var.tenant_config.batch_enabled ? aws_batch_job_queue.this[0].arn : "disabled"
  tags  = local.tenant_tags
}

# Glue
resource "aws_ssm_parameter" "glue_database_name" {
  name  = "${local.ssm_prefix}/glue-database-name"
  type  = "String"
  value = aws_glue_catalog_database.this.name
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "glue_registry_name" {
  name  = "${local.ssm_prefix}/glue-registry-name"
  type  = "String"
  value = var.tenant_config.schema_registry_enabled ? aws_glue_registry.this[0].registry_name : "disabled"
  tags  = local.tenant_tags
}

# IRSA Roles
resource "aws_ssm_parameter" "irsa_worker_role_arn" {
  name  = "${local.ssm_prefix}/irsa-worker-role-arn"
  type  = "String"
  value = module.worker_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "irsa_orchestrator_role_arn" {
  name  = "${local.ssm_prefix}/irsa-orchestrator-role-arn"
  type  = "String"
  value = module.orchestrator_irsa.iam_role_arn
  tags  = local.tenant_tags
}

resource "aws_ssm_parameter" "irsa_connector_role_arn" {
  name  = "${local.ssm_prefix}/irsa-connector-role-arn"
  type  = "String"
  value = module.connector_irsa.iam_role_arn
  tags  = local.tenant_tags
}

# Namespace
resource "aws_ssm_parameter" "namespace" {
  name  = "${local.ssm_prefix}/namespace"
  type  = "String"
  value = local.namespace
  tags  = local.tenant_tags
}
