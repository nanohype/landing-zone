/**
 * ElastiCache Redis replication group — shared state for almanac's
 * sliding-window rate limiter (src/ratelimit/redis-limiter.ts). Multi-
 * instance pods cannot use in-memory Maps; the limiter would multiply
 * the actual limit by replica count without a shared backend.
 *
 * Production posture: multi-AZ with automatic failover, 2 cache
 * clusters (primary + read replica). Dev/staging runs single-node.
 */

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${local.prefix}-redis"
  subnet_ids = var.private_subnet_ids

  tags = local.common_tags
}

resource "aws_security_group" "redis" {
  name_prefix = "${local.prefix}-redis-"
  description = "Security group for ElastiCache Redis — almanac ${var.environment}"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [var.cluster_sg_id]
    description     = "Redis from EKS"
  }

  tags = merge(local.common_tags, {
    Name = "${local.prefix}-redis"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "rate_limit" {
  replication_group_id = "${local.prefix}-ratelimit"
  description          = "almanac ${var.environment} rate-limiting Redis"

  engine             = "redis"
  engine_version     = "7.1"
  node_type          = var.redis_node_type
  num_cache_clusters = var.redis_num_cache_clusters

  port               = 6379
  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  automatic_failover_enabled = var.redis_multi_az
  multi_az_enabled           = var.redis_multi_az

  apply_immediately = var.environment != "production"

  tags = local.common_tags
}
