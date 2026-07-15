data "aws_partition" "current" {}

locals {
  # Expand the tenant's model allowlist into the ARNs a Bedrock invoke grant
  # needs — the foundation-model ARN (AWS-owned, any region) plus the account's
  # cross-region inference profiles that route to it (their IDs carry a
  # us./eu./apac. region-set prefix, hence the leading wildcard). Invoking via an
  # inference profile authorizes against both the profile and the underlying
  # model, so a usable allowlist grants both. Empty allowlist => ["*"].
  bedrock_invoke_resources = length(var.tenant_config.bedrock_allowed_model_ids) == 0 ? ["*"] : flatten([
    for id in var.tenant_config.bedrock_allowed_model_ids : [
      "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/${id}",
      "arn:${data.aws_partition.current.partition}:bedrock:*:${var.account_id}:inference-profile/*${id}",
    ]
  ])
}

module "bedrock_api_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-bedrock-api"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "bedrock-api"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      Resource = local.bedrock_invoke_resources
    },
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = [
        module.document_bucket.s3_bucket_arn,
        "${module.document_bucket.s3_bucket_arn}/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      Resource = [aws_kms_key.documents.arn]
    },
    {
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan",
      ]
      Resource = [aws_dynamodb_table.conversations.arn]
    },
    {
      Effect   = "Allow"
      Action   = ["aoss:APIAccessAll"]
      Resource = [aws_opensearchserverless_collection.vectors.arn]
    },
  ]

  tags = local.tenant_tags
}
