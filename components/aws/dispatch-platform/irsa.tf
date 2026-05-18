/**
 * IRSA role for dispatch's shared ServiceAccount (used by pipeline,
 * api, and web Deployments in the chart, plus the migrate-job hook).
 * One consolidated inline policy covers everything the Platform CR's
 * placeholder ARNs reference.
 */

module "dispatch_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name         = "${local.prefix}-platform"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_issuer       = var.oidc_issuer
  namespace         = var.namespace
  service_account   = var.service_account

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject",
      ]
      Resource = [
        aws_s3_bucket.voice_baseline.arn,
        "${aws_s3_bucket.voice_baseline.arn}/*",
        aws_s3_bucket.raw_aggregations.arn,
        "${aws_s3_bucket.raw_aggregations.arn}/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "ses:SendEmail",
        "ses:SendRawEmail",
        "ses:GetSendQuota",
      ]
      Resource = [
        aws_sesv2_email_identity.dispatch.arn,
        aws_sesv2_configuration_set.dispatch.arn,
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
      ]
      Resource = [
        # Claude Sonnet 4 + 4.6 — cross-region inference + foundation
        # model ARNs. Newsletter generator uses whichever model the
        # BEDROCK_MODEL_ID env points at.
        "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-sonnet-4-6*",
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6*",
        "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/us.anthropic.claude-sonnet-4*",
        "arn:aws:bedrock:*::foundation-model/anthropic.claude-sonnet-4*",
      ]
    },
    {
      # Secrets Manager: dispatch/<env>/db-credentials (managed by RDS),
      # plus operator-seeded approvers, workos-directory, grafana-cloud.
      # The chart's ExternalSecret resolves all four.
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = [
        "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:dispatch/${var.environment}/*",
        # RDS master credentials live at the secret-arn the Aurora
        # module manages; pulled by ARN rather than path because the
        # module owns the naming.
        module.aurora.cluster_master_user_secret[0].secret_arn,
      ]
    },
    {
      # Best-effort metrics fallback when OTel isn't reachable.
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData"]
      Resource = ["*"]
    },
  ]

  tags = local.common_tags
}
