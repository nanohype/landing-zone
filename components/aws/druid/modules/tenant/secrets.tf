################################################################################
# Secrets Manager (Aurora credentials bridge)
################################################################################

resource "aws_secretsmanager_secret" "aurora_credentials" {
  name        = "druid/${var.environment}/${var.tenant_id}/aurora/credentials"
  description = "Aurora PostgreSQL credentials for Druid tenant ${var.tenant_id}"

  # A deleted secret holds its name for the recovery window and refuses to be re-minted
  # under it, and this name is deterministic — so the default 30 days turns a permitted
  # teardown into a month-long block on the re-install that teardown exists to enable.
  # managed-monitoring reasons the same way about its own cluster-scoped secrets.
  recovery_window_in_days = local.allow_teardown ? 0 : 30

  tags = local.tenant_tags
}

resource "aws_secretsmanager_secret_version" "aurora_credentials" {
  secret_id = aws_secretsmanager_secret.aurora_credentials.id
  secret_string = jsonencode({
    username = module.aurora.cluster_master_username
    host     = module.aurora.cluster_endpoint
    port     = module.aurora.cluster_port
    dbname   = local.db_name
  })
}

resource "aws_secretsmanager_secret" "msk_config" {
  count = var.tenant_config.msk_enabled ? 1 : 0

  name        = "druid/${var.environment}/${var.tenant_id}/msk/config"
  description = "MSK configuration for Druid tenant ${var.tenant_id}"

  # A deleted secret holds its name for the recovery window and refuses to be re-minted
  # under it, and this name is deterministic — so the default 30 days turns a permitted
  # teardown into a month-long block on the re-install that teardown exists to enable.
  # managed-monitoring reasons the same way about its own cluster-scoped secrets.
  recovery_window_in_days = local.allow_teardown ? 0 : 30

  tags = local.tenant_tags
}

resource "aws_secretsmanager_secret_version" "msk_config" {
  count = var.tenant_config.msk_enabled ? 1 : 0

  secret_id = aws_secretsmanager_secret.msk_config[0].id
  secret_string = jsonencode({
    bootstrap_servers = aws_msk_serverless_cluster.this[0].arn
  })
}

resource "aws_secretsmanager_secret" "s3_config" {
  name        = "druid/${var.environment}/${var.tenant_id}/s3/config"
  description = "S3 bucket configuration for Druid tenant ${var.tenant_id}"

  # A deleted secret holds its name for the recovery window and refuses to be re-minted
  # under it, and this name is deterministic — so the default 30 days turns a permitted
  # teardown into a month-long block on the re-install that teardown exists to enable.
  # managed-monitoring reasons the same way about its own cluster-scoped secrets.
  recovery_window_in_days = local.allow_teardown ? 0 : 30

  tags = local.tenant_tags
}

resource "aws_secretsmanager_secret_version" "s3_config" {
  secret_id = aws_secretsmanager_secret.s3_config.id
  secret_string = jsonencode({
    deepstorage = module.deepstorage_bucket.s3_bucket_id
    indexlogs   = module.indexlogs_bucket.s3_bucket_id
    msq         = module.msq_bucket.s3_bucket_id
  })
}
