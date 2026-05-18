/**
 * dispatch-platform — AWS substrate for the dispatch newsletter Platform
 * tenant. Single-tenant by design (same rationale as marshal-platform
 * and almanac-platform).
 *
 * Resources, mapped to dispatch's CDK-era stack:
 *   - Aurora Serverless v2 (PostgreSQL): drafts + audit_events tables.
 *     The chart's migrate-job Helm hook applies schema migrations
 *     against this DB before any new pipeline/api/web pod rolls out.
 *   - S3 ×2: voice-baseline (immutable few-shot corpus) +
 *     raw-aggregations (per-run snapshots, lifecycle-expired).
 *   - SES verified sending identity for the configured domain;
 *     IRSA policy scopes SendEmail to that identity ARN.
 *   - IRSA role bundling Aurora-via-secret, S3 R/W, SES SendEmail,
 *     Bedrock InvokeModel (Claude Sonnet 4 / 4.6), and Secrets
 *     Manager Read on dispatch/<env>/*.
 *
 * Wired by live/_envcommon/aws/dispatch-platform.hcl. The chart's
 * ExternalSecret aggregates four Secrets Manager entries
 * (db-credentials from RDS, approvers + workos-directory +
 * grafana-cloud from the operator-seeded set) into one k8s Secret.
 */

locals {
  prefix      = "dispatch-${var.environment}"
  common_tags = merge({ Component = "dispatch-platform", Tenant = "dispatch" }, var.tags)
}

data "aws_caller_identity" "current" {}
