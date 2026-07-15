/**
 * DynamoDB tables for incident-response.
 *
 * incidents:
 *   PK: incident_id (String)
 *   GSI slack-channel-index: channel_id → incident_id (used by
 *   src/utils/incident-lookup.ts for channel-scoped /incident-response subcommands)
 *
 * audit:
 *   PK: incident_id (String)
 *   SK: audit_id (String, ULID for stable sort)
 *   GSI by-timestamp: timestamp → incident_id (operator queries the audit
 *   log by time window during postmortems and compliance sweeps)
 *
 * identity-cache:
 *   PK: external_user_id (String — Slack U…, Grafana OnCall numeric)
 *   TTL attribute: ttl (Number — unix seconds; expires the 1h
 *   WorkOS Directory Sync cache so org changes propagate)
 */

resource "aws_dynamodb_table" "incidents" {
  name         = "${local.prefix}-incidents"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"

  attribute {
    name = "incident_id"
    type = "S"
  }
  attribute {
    name = "channel_id"
    type = "S"
  }

  global_secondary_index {
    name            = "slack-channel-index"
    hash_key        = "channel_id"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  deletion_protection_enabled = var.deletion_protection

  tags = local.tags
}

resource "aws_dynamodb_table" "audit" {
  name         = "${local.prefix}-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "incident_id"
  range_key    = "audit_id"

  attribute {
    name = "incident_id"
    type = "S"
  }
  attribute {
    name = "audit_id"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }

  global_secondary_index {
    name            = "by-timestamp"
    hash_key        = "timestamp"
    range_key       = "incident_id"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  deletion_protection_enabled = var.deletion_protection

  tags = local.tags
}

resource "aws_dynamodb_table" "identity_cache" {
  name         = "${local.prefix}-identity-cache"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "external_user_id"

  attribute {
    name = "external_user_id"
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

  tags = local.tags
}
