################################################################################
# cache -> ElastiCache (Valkey / Redis)
################################################################################

resource "aws_elasticache_subnet_group" "cache" {
  for_each = local.cache_stores

  name       = "${local.prefix}-${each.key}"
  subnet_ids = var.private_subnets

  tags = local.tenant_tags
}

resource "aws_security_group" "cache" {
  for_each = local.cache_stores

  name_prefix = "${local.prefix}-${each.key}-cache-"
  description = "ElastiCache access for ${var.tenant_id}/${each.key}"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.cluster_sg_id]
    description     = "Cache from EKS"
  }

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-${each.key}-cache" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "cache" {
  for_each = local.cache_stores

  replication_group_id = "${local.prefix}-${each.key}"
  description          = "${var.tenant_id}/${each.key} ${each.value.cache.engine} cache"

  engine    = each.value.cache.engine
  node_type = each.value.cache.node_type

  # replicas is the read-replica count; num_cache_clusters counts the primary
  # too. Failover and multi-AZ need at least one replica, so they track it.
  num_cache_clusters         = each.value.cache.replicas + 1
  automatic_failover_enabled = each.value.cache.replicas > 0
  multi_az_enabled           = each.value.cache.replicas > 0

  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.cache[each.key].name
  security_group_ids = [aws_security_group.cache[each.key].id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  apply_immediately = var.environment != "production"

  tags = local.data_tags
}
