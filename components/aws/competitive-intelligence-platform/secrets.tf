/**
 * Secrets Manager app-secrets for competitive-intelligence.
 *
 * Seeded with a placeholder JSON shape so the secret exists for the
 * chart's ExternalSecret to bind at pod start; the real values are
 * filled in out-of-band (no credentials live in state). Subsequent
 * value rotations are owned outside Terraform, so secret_string drift
 * is ignored after the initial seed.
 *
 * db-credentials are NOT seeded here — they come from Aurora's
 * manage_master_user_password managed secret (see aurora.tf and the
 * aurora_master_user_secret_arn output).
 */

resource "aws_secretsmanager_secret" "app_secrets" {
  name        = "competitive-intelligence/${var.environment}/app-secrets"
  description = "Application secrets for competitive-intelligence ${var.environment} (Slack + optional LLM API credentials)."

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "app_secrets" {
  secret_id = aws_secretsmanager_secret.app_secrets.id
  secret_string = jsonencode({
    SLACK_BOT_TOKEN      = ""
    SLACK_SIGNING_SECRET = ""
    SLACK_APP_TOKEN      = ""
    ANTHROPIC_API_KEY    = ""
    OPENAI_API_KEY       = ""
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
