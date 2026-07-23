################################################################################
# relational -> Aurora PostgreSQL Serverless v2
################################################################################

resource "aws_db_subnet_group" "relational" {
  for_each = local.relational_stores

  name       = "${local.prefix}-${each.key}"
  subnet_ids = var.private_subnets

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-${each.key}" })
}

module "relational" {
  source   = "terraform-aws-modules/rds-aurora/aws"
  version  = "~> 9.0"
  for_each = local.relational_stores

  name           = "${local.prefix}-${each.key}"
  engine         = "aurora-postgresql"
  engine_mode    = "provisioned"
  engine_version = each.value.relational.engine_version

  database_name   = "app_${replace(each.key, "-", "_")}"
  master_username = "app_admin"

  # RDS manages the master credential in Secrets Manager; the operator publishes
  # the resolved secret name into the CR status so the chart reads one place.
  manage_master_user_password = true

  vpc_id               = var.vpc_id
  db_subnet_group_name = aws_db_subnet_group.relational[each.key].name
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
    min_capacity = each.value.relational.min_acu
    max_capacity = each.value.relational.max_acu
  }

  instance_class = "db.serverless"
  instances = {
    one = {}
  }

  backup_retention_period = each.value.relational.backup_retention_days
  deletion_protection     = each.value.relational.deletion_protection

  tags = local.data_tags
}
