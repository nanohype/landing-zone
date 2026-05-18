/**
 * Aurora Serverless v2 (PostgreSQL) — retrieval backend for almanac's
 * pgvector + BM25 hybrid search. The pgvector extension itself is
 * created at app bootstrap (CREATE EXTENSION vector + table DDL in
 * src/rag/backends/pgvector-schema.ts) — Aurora just supplies the
 * Postgres engine + storage.
 *
 * Module mirrors the druid component's tenant Aurora setup
 * (terraform-aws-modules/rds-aurora/aws ~9.0): one db.serverless
 * instance with min/max ACU sized via tenant_config, security group
 * restricted to the EKS cluster SG.
 *
 * Master credentials managed by RDS into a Secrets Manager secret named
 * by the RDS module; almanac/<env>/db-credentials is the canonical
 * pointer that the chart's ExternalSecret resolves at pod start.
 */

resource "aws_db_subnet_group" "aurora" {
  name       = "${local.prefix}-aurora"
  subnet_ids = var.private_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-aurora"
  })
}

resource "aws_security_group" "aurora" {
  name_prefix = "${local.prefix}-aurora-"
  description = "Security group for Aurora PostgreSQL — almanac ${var.environment}"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.cluster_sg_id]
    description     = "PostgreSQL from EKS"
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-aurora"
  })

  lifecycle {
    create_before_destroy = true
  }
}

module "aurora" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 9.0"

  name           = "${local.prefix}-aurora"
  engine         = "aurora-postgresql"
  engine_mode    = "provisioned"
  engine_version = "16.6"

  database_name   = "almanac"
  master_username = "almanac_admin"

  manage_master_user_password = true

  vpc_id               = var.vpc_id
  db_subnet_group_name = aws_db_subnet_group.aurora.name
  security_group_rules = {
    eks_ingress = {
      type                     = "ingress"
      from_port                = 5432
      to_port                  = 5432
      source_security_group_id = var.cluster_sg_id
      description              = "PostgreSQL from EKS"
    }
  }

  storage_encrypted = true
  apply_immediately = var.environment != "production"

  serverlessv2_scaling_configuration = {
    min_capacity = var.rds_min_acu
    max_capacity = var.rds_max_acu
  }

  instance_class = "db.serverless"
  instances = {
    one = {}
  }

  backup_retention_period = var.rds_backup_retention_days
  deletion_protection     = var.deletion_protection

  tags = local.common_tags
}
