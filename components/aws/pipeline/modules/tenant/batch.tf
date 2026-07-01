################################################################################
# AWS Batch — Fargate Compute Environment + Job Queue (Conditional)
################################################################################

resource "aws_batch_compute_environment" "this" {
  count = var.tenant_config.batch_enabled ? 1 : 0

  name  = local.prefix
  type  = "MANAGED"
  state = "ENABLED"

  compute_resources {
    type      = var.tenant_config.batch_type
    max_vcpus = var.tenant_config.batch_max_vcpus

    subnets            = var.private_subnets
    security_group_ids = [aws_security_group.batch[0].id]
  }

  tags = local.tenant_tags
}

resource "aws_batch_job_queue" "this" {
  count = var.tenant_config.batch_enabled ? 1 : 0

  name     = local.prefix
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.this[0].arn
  }

  tags = local.tenant_tags
}

resource "aws_security_group" "batch" {
  count       = var.tenant_config.batch_enabled ? 1 : 0
  name_prefix = "${local.prefix}-batch-"
  description = "Batch security group for pipeline - ${var.tenant_id}"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Batch compute egress (image pulls, S3, Glue, CloudWatch)"
  }

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-batch" })

  lifecycle { create_before_destroy = true }
}
