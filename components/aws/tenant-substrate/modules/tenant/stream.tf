################################################################################
# stream -> MSK Serverless (IAM auth)
################################################################################

resource "aws_security_group" "stream" {
  for_each = local.stream_stores

  name_prefix = "${local.prefix}-${each.key}-msk-"
  description = "MSK Serverless access for ${var.tenant_id}/${each.key}"
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
    description = "Allow all outbound"
  }

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-${each.key}-msk" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_msk_serverless_cluster" "stream" {
  for_each = local.stream_stores

  cluster_name = "${local.prefix}-${each.key}"

  vpc_config {
    subnet_ids         = var.private_subnets
    security_group_ids = [aws_security_group.stream[each.key].id]
  }

  client_authentication {
    sasl {
      iam {
        enabled = true
      }
    }
  }

  tags = local.data_tags
}
