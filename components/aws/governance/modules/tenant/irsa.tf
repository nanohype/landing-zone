module "audit_writer_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-audit-writer"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "audit-writer"

  policy_statements = concat([
    {
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = ["${module.audit_bucket.s3_bucket_arn}/*"]
    },
    {
      Effect   = "Allow"
      Action   = ["kms:GenerateDataKey", "kms:Encrypt"]
      Resource = [aws_kms_key.audit.arn]
    },
    {
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:BatchWriteItem"]
      Resource = [aws_dynamodb_table.audit.arn, aws_dynamodb_table.cost.arn]
    },
    {
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData", "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["*"]
    },
    ], var.tenant_config.event_bridge_enabled ? [
    {
      Effect   = "Allow"
      Action   = ["events:PutEvents"]
      Resource = [aws_cloudwatch_event_bus.this[0].arn]
    },
  ] : [])

  tags = local.tenant_tags
}

module "governance_api_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-governance-api"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "governance-api"

  policy_statements = [
    {
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [module.audit_bucket.s3_bucket_arn, "${module.audit_bucket.s3_bucket_arn}/*", module.guardrail_bucket.s3_bucket_arn, "${module.guardrail_bucket.s3_bucket_arn}/*"]
    },
    {
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
      Resource = [aws_dynamodb_table.audit.arn, "${aws_dynamodb_table.audit.arn}/index/*", aws_dynamodb_table.cost.arn, "${aws_dynamodb_table.cost.arn}/index/*"]
    },
    {
      Effect   = "Allow"
      Action   = ["cloudwatch:GetMetricData", "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["*"]
    },
  ]

  tags = local.tenant_tags
}
