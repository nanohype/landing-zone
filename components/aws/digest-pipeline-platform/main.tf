/**
 * digest-pipeline-platform — AWS substrate for the digest-pipeline newsletter Platform
 * tenant. Single-tenant by design (same rationale as incident-response-platform
 * and slack-knowledge-bot-platform).
 *
 * Resources:
 *   - Aurora Serverless v2 (PostgreSQL): drafts + audit_events tables.
 *     The chart's migrate-job Helm hook applies schema migrations
 *     against this DB before any new pipeline/api/web pod rolls out.
 *   - S3 ×2: voice-baseline (immutable few-shot corpus) +
 *     raw-aggregations (per-run snapshots, lifecycle-expired).
 *   - SES verified sending identity for the configured domain;
 *     IRSA policy scopes SendEmail to that identity ARN.
 *   - IRSA role bundling Aurora-via-secret, S3 R/W, SES SendEmail,
 *     Bedrock InvokeModel (Claude Sonnet 4 / 4.6), and Secrets
 *     Manager Read on digest-pipeline/<env>/*.
 *
 * Wired by live/_envcommon/aws/digest-pipeline-platform.hcl. The chart's
 * ExternalSecret aggregates four Secrets Manager entries
 * (db-credentials from RDS, approvers + workos-directory +
 * grafana-cloud from the operator-seeded set) into one k8s Secret.
 */

locals {
  prefix = "digest-pipeline-${var.environment}"
  tags   = merge({ Component = "digest-pipeline-platform", Tenant = "digest-pipeline" }, var.tags)
}

data "aws_caller_identity" "current" {}
