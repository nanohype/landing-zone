/**
 * Aurora Serverless v2 (PostgreSQL) — drafts + audit_events tables.
 * Schema migrations land via the chart's pre-install/pre-upgrade Job
 * hook (`npm run migrate:up` against the api image) before any pipeline/
 * api/web pod from the new version starts.
 *
 * Module mirrors druid + almanac-platform: terraform-aws-modules/
 * rds-aurora/aws ~9.0, db.serverless instance, security group scoped
 * to the EKS cluster SG.
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
  description = "Security group for Aurora PostgreSQL — dispatch ${var.environment}"
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

  database_name   = "dispatch"
  master_username = "dispatch_admin"

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
