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

  # Teardown posture: development always allows a full destroy; elsewhere it is
  # opt-in via force_destroy_buckets (same two-act contract as agent-iam). Without
  # skip_final_snapshot=true OR a final_snapshot_identifier, the provider refuses
  # the destroy with "final_snapshot_identifier is required when skip_final_snapshot
  # is false" — which is the wedge that stranded every environment before this local.
  allow_teardown = var.environment == "development" || var.force_destroy_buckets
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

  name        = "${local.prefix}-aurora"
  engine      = "aurora-postgresql"
  engine_mode = "provisioned"
  # Major-only by design. RDS resolves it to the newest minor the region offers,
  # so a retired patch cannot strand the component. A full pin bets on what AWS
  # still offers in every region an adopter deploys into, and that differs by
  # region — pinned at "16.6" this failed every apply with `Cannot find version
  # 16.6 for aurora-postgresql` once AWS withdrew it, after the VPC and the EKS
  # cluster were already built and billing. Enforced by
  # scripts/check-engine-version-pins.py.
  engine_version = "16"

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

  # Every teardown gate moves on one lever. A permitted teardown clears protection
  # here in the same apply that lands force_destroy on the buckets, so the destroy
  # that follows reaches both; otherwise the leaf's own pin stands.
  #
  # Splitting the two is worse than either posture on its own: the bucket modules
  # hold no reference to this cluster, so the graph walker destroys them
  # concurrently. Protection left armed while the snapshot is skipped means the
  # buckets empty, DeleteDBCluster fails, and the reverse sweep halts above
  # cluster and network — deepstorage gone, the database still standing, and EKS,
  # VPC and NAT still billing.
  deletion_protection = local.allow_teardown ? false : var.tenant_config.deletion_protection

  # Always set one of these so the destroy is reachable. Development /
  # force_destroy_buckets skip the snapshot; otherwise take a final snapshot under
  # a stable identifier so a careful teardown still works.
  skip_final_snapshot       = local.allow_teardown
  final_snapshot_identifier = local.allow_teardown ? null : "${local.prefix}-aurora-final"

  tags = local.tenant_tags
}
