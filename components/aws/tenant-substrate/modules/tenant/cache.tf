################################################################################
# cache -> ElastiCache (Valkey / Redis)
#
# Transit encryption alone is not enough: without AUTH, any principal that can
# open a TCP session to the security group can read and write the cache. The
# cluster node SG is wide enough that a compromised tenant pod on the same
# cluster would otherwise reach every co-located tenant's cache. AUTH is the
# application-layer clamp; the token is minted here and stored under the
# tenant's CMK so only a role granted that secret can connect.
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
    security_groups = [var.node_sg_id]
    description     = "Cache from EKS"
  }

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-${each.key}-cache" })

  lifecycle {
    create_before_destroy = true
  }
}

# 16–128 chars, no specials Redis AUTH rejects. Lifetime of the replication
# group: rotating requires auth_token_update_strategy and a coordinated app cut.
resource "random_password" "cache_auth" {
  for_each = local.cache_stores

  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "cache_auth" {
  for_each = local.cache_stores

  name        = "${local.prefix}/${each.key}/auth-token"
  description = "ElastiCache AUTH token for ${var.tenant_id}/${each.key}. Required on every connection when transit encryption is on."
  kms_key_id  = aws_kms_key.tenant.arn

  # A deleted secret holds its name for the recovery window and refuses to be re-minted
  # under it, and this name is deterministic — so the default 30 days turns a permitted
  # teardown into a month-long block on the re-install that teardown exists to enable.
  # managed-monitoring reasons the same way about its own cluster-scoped secrets.
  recovery_window_in_days = local.allow_teardown ? 0 : 30

  tags = local.tenant_tags
}

resource "aws_secretsmanager_secret_version" "cache_auth" {
  for_each = local.cache_stores

  secret_id     = aws_secretsmanager_secret.cache_auth[each.key].id
  secret_string = random_password.cache_auth[each.key].result
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
  # AUTH token: SG membership is necessary but not sufficient. Without this,
  # any workload on the cluster node SG could read the cache over TLS.
  auth_token = random_password.cache_auth[each.key].result

  apply_immediately = var.environment != "production"

  tags = local.datastore_tags["cache"]
}
