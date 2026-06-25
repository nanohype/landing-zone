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
      Resource = ["*"]
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
