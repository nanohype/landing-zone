################################################################################
# Aurora PostgreSQL Serverless v2
################################################################################

locals {
  db_name     = "druid_${replace(var.tenant_id, "-", "_")}"
  db_username = "druid_admin"
  prefix      = "${var.environment}-druid-${var.tenant_id}"
  # Account-qualified so S3 bucket names are globally unique (S3's namespace is
  # global). The component's `tenants` variable validation asserts the composed
  # length fits 63.
  bucket_prefix = "${local.prefix}-${var.account_id}"
  tenant_tags   = merge(var.tags, { Tenant = var.tenant_id })
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.prefix}-aurora"
  subnet_ids = var.private_subnets

  tags = merge(local.tenant_tags, {
    Name = "${local.prefix}-aurora"
  })
}

resource "aws_security_group" "aurora" {
  name_prefix = "${local.prefix}-aurora-"
  description = "Security group for Aurora PostgreSQL - ${var.tenant_id}"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.cluster_sg_id]
    description     = "PostgreSQL from EKS"
  }

  tags = merge(local.tenant_tags, {
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

  database_name   = local.db_name
  master_username = local.db_username

  manage_master_user_password = true

  vpc_id               = var.vpc_id
  db_subnet_group_name = aws_db_subnet_group.this.name
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
    min_capacity = var.tenant_config.rds_min_acu
    max_capacity = var.tenant_config.rds_max_acu
  }

  instance_class = "db.serverless"
  instances = {
    one = {}
  }

  backup_retention_period = var.tenant_config.rds_backup_days
  deletion_protection     = var.tenant_config.deletion_protection

  tags = local.tenant_tags
}
