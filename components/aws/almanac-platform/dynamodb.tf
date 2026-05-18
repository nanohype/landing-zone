/**
 * DynamoDB tables for almanac.
 *
 * tokens — per-(user, provider) OAuth token store.
 *   PK userId / SK provider. KMS-encrypted payload via the token-store
 *   CMK; the EncryptionContext binds the ciphertext to the user+provider
 *   pair so a leaked blob can't be decrypted across pairs.
 *
 * audit — query/revocation audit log.
 *   PK userId / SK timestamp. TTL window so DDB reaps hot records into
 *   S3 after `audit_ttl_days`.
 *
 * identity-cache — Slack → workforce-directory cache.
 *   PK slackUserId. TTL attribute drives the 1h cache invalidation.
 */

resource "aws_dynamodb_table" "tokens" {
  name         = "${local.prefix}-tokens"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"
  range_key    = "provider"

  attribute {
    name = "userId"
    type = "S"
  }
  attribute {
    name = "provider"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  deletion_protection_enabled = var.deletion_protection

  tags = local.common_tags
}

resource "aws_dynamodb_table" "audit" {
  name         = "${local.prefix}-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userId"
  range_key    = "timestamp"

  attribute {
    name = "userId"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  deletion_protection_enabled = var.deletion_protection

  tags = local.common_tags
}

resource "aws_dynamodb_table" "identity_cache" {
  name         = "${local.prefix}-identity-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "slackUserId"

  attribute {
    name = "slackUserId"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false # cache, not source of truth
  }

  deletion_protection_enabled = var.deletion_protection

  tags = local.common_tags
}
