module "inference_server_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-inference-server"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "inference-server"

  policy_statements = concat([
    {
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [module.model_bucket.s3_bucket_arn, "${module.model_bucket.s3_bucket_arn}/*"]
    },
    {
      Effect   = "Allow"
      Action   = ["kms:Decrypt", "kms:DescribeKey"]
      Resource = [aws_kms_key.models.arn]
    },
    {
      Effect   = "Allow"
      Action   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite", "elasticfilesystem:ClientRootAccess"]
      Resource = [aws_efs_file_system.models.arn]
    },
    {
      Effect   = "Allow"
      Action   = ["ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage", "ecr:GetAuthorizationToken"]
      Resource = ["*"]
    },
    {
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData", "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["*"]
    },
    ], var.tenant_config.hf_token_enabled ? [
    {
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.hf_token[0].arn]
    },
  ] : [])

  tags = local.tenant_tags
}

module "api_gateway_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-api-gateway"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "api-gateway"

  policy_statements = [
    {
      Effect   = "Allow"
      Action   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:GetQueueAttributes"]
      Resource = [aws_sqs_queue.inference.arn]
    },
    {
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Query", "dynamodb:Scan"]
      Resource = [aws_dynamodb_table.inference.arn]
    },
    {
      Effect   = "Allow"
      Action   = ["cloudwatch:PutMetricData", "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["*"]
    },
  ]

  tags = local.tenant_tags
}
