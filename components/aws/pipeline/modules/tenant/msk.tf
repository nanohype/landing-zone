################################################################################
# MSK Serverless (Conditional)
################################################################################

resource "aws_msk_serverless_cluster" "this" {
  count        = var.tenant_config.msk_enabled ? 1 : 0
  cluster_name = local.prefix

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = [aws_security_group.msk[0].id]
  }

  client_authentication {
    sasl {
      iam { enabled = true }
    }
  }

  tags = local.tenant_tags
}

resource "aws_security_group" "msk" {
  count       = var.tenant_config.msk_enabled ? 1 : 0
  name_prefix = "${local.prefix}-msk-"
  description = "MSK security group for pipeline - ${var.tenant_id}"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 9098
    to_port         = 9098
    protocol        = "tcp"
    security_groups = [var.cluster_sg_id]
    description     = "MSK IAM auth from EKS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "MSK broker egress (inter-broker replication, CloudWatch)"
  }

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-msk" })

  lifecycle { create_before_destroy = true }
}
