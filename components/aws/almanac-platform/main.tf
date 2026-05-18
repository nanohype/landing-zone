/**
 * almanac-platform — AWS substrate for the almanac Slack-knowledge-bot
 * Platform tenant. Single-tenant by design (same rationale as
 * marshal-platform).
 *
 * Resources, mapped to almanac's CDK-era stack:
 *   - KMS key for per-user OAuth token envelope encryption
 *   - DynamoDB ×3: tokens / audit / identity-cache (with TTL on audit +
 *     identity-cache)
 *   - ElastiCache Redis replication group: rate-limit shared state
 *   - Aurora Serverless v2 (PostgreSQL): retrieval backend with pgvector
 *     extension created at app bootstrap, not at infra layer
 *   - SQS FIFO audit queue + DLQ
 *   - S3 audit-archive bucket with Intelligent-Tiering after 90d
 *   - IRSA role bundling DDB / SQS / S3 / KMS / Bedrock / Secrets Manager
 *     into one policy attached to the shared ServiceAccount
 *
 * Wired by live/_envcommon/aws/almanac-platform.hcl. Output ARNs flow
 * into the protohype/almanac Platform CR's spec.irsa.policies via the
 * operator-side identity propagation layer.
 */

locals {
  prefix      = "almanac-${var.environment}"
  common_tags = merge({ Component = "almanac-platform", Tenant = "almanac" }, var.tags)
}

data "aws_caller_identity" "current" {}
