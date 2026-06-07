/**
 * competitive-intelligence-platform — AWS substrate for the
 * competitive-intelligence Platform tenant of the protohype team.
 * Single-tenant by design (same rationale as slack-knowledge-bot-platform).
 *
 * Resources:
 *   - Aurora Serverless v2 (PostgreSQL): retrieval backend with the
 *     pgvector extension created at app bootstrap, not at the infra layer
 *   - Secrets Manager app-secrets: Slack + optional LLM API credentials,
 *     seeded with a placeholder shape the app fills in out-of-band
 *   - IRSA role bundling Aurora-managed-secret / app-secrets / Bedrock /
 *     CloudWatch into one policy attached to the tenant ServiceAccount
 *
 * Wired by live/_envcommon/aws/competitive-intelligence-platform.hcl.
 * Output ARNs flow into the protohype/competitive-intelligence Platform
 * CR's spec.irsa.policies via the operator-side identity propagation
 * layer.
 */

locals {
  prefix      = "competitive-intelligence-${var.environment}"
  common_tags = merge({ Component = "competitive-intelligence-platform", Tenant = "competitive-intelligence" }, var.tags)
}

data "aws_caller_identity" "current" {}
