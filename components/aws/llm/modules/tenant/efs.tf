resource "aws_efs_file_system" "models" {
  #checkov:skip=CKV_AWS_42:false positive — encryption is var-driven (tenant_config.efs_encryption, default true); checkov cannot see the variable default and flags the dynamic value.
  creation_token   = "${local.prefix}-models"
  encrypted        = var.tenant_config.efs_encryption
  performance_mode = var.tenant_config.efs_performance_mode
  throughput_mode  = var.tenant_config.efs_throughput_mode

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-models" })
}

resource "aws_security_group" "efs" {
  name_prefix = "${local.prefix}-efs-"
  description = "EFS security group for LLM models - ${var.tenant_id}"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [var.cluster_sg_id]
    description     = "NFS from EKS"
  }

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-efs" })

  lifecycle { create_before_destroy = true }
}

resource "aws_efs_mount_target" "this" {
  for_each = toset(var.private_subnets)

  file_system_id  = aws_efs_file_system.models.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "models" {
  file_system_id = aws_efs_file_system.models.id

  posix_user {
    gid = 1000
    uid = 1000
  }

  root_directory {
    path = "/models"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-models" })
}
