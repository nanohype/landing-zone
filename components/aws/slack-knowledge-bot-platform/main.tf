/**
 * slack-knowledge-bot-platform — AWS substrate for the slack-knowledge-bot Slack knowledge bot
 * Platform tenant. Single-tenant by design (same rationale as
 * incident-response-platform).
 *
 * Resources:
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
 * Wired by live/_envcommon/aws/slack-knowledge-bot-platform.hcl. Output ARNs flow
 * into the slack-knowledge-bot Platform CR's spec.irsa.policies via the
 * operator-side identity propagation layer.
 */

locals {
  prefix     = "${var.environment}-slack-knowledge-bot"
  account_id = data.aws_caller_identity.current.account_id
  tags = merge({
    Component = "slack-knowledge-bot-platform"
    Tenant    = "slack-knowledge-bot"
    Team      = var.team
  }, var.tags)
}

data "aws_caller_identity" "current" {}
