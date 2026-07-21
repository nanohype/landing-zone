################################################################################
# Pod Identity Roles for MLOps Components
################################################################################

locals {
  datasets_bucket_arn  = module.datasets_bucket.s3_bucket_arn
  artifacts_bucket_arn = module.artifacts_bucket.s3_bucket_arn

  all_bucket_arns = [
    local.datasets_bucket_arn,
    local.artifacts_bucket_arn,
  ]

  all_bucket_object_arns = [
    "${local.datasets_bucket_arn}/*",
    "${local.artifacts_bucket_arn}/*",
  ]

  ecr_repo_arn = var.tenant_config.ecr_enabled ? aws_ecr_repository.this[0].arn : ""
}

# Training Worker: S3 rw on both buckets, KMS encrypt/decrypt, DynamoDB rw on
# experiments, SQS consume on training queue, ECR pull, CloudWatch
module "training_worker_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-training-worker"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "mlops-training-worker"

  policy_statements = concat([
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]
      Resource = concat(local.all_bucket_arns, local.all_bucket_object_arns)
    },
    {
      Effect = "Allow"
      Action = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      Resource = [aws_kms_key.this.arn]
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
        "dynamodb:BatchWriteItem",
        "dynamodb:BatchGetItem",
      ]
      Resource = [
        aws_dynamodb_table.experiments.arn,
        "${aws_dynamodb_table.experiments.arn}/index/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility",
      ]
      Resource = [aws_sqs_queue.training.arn]
    },
    {
      Effect = "Allow"
      Action = [
        "cloudwatch:PutMetricData",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = ["*"]
    },
    ], var.tenant_config.ecr_enabled ? [
    {
      Effect = "Allow"
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetAuthorizationToken",
      ]
      Resource = [local.ecr_repo_arn]
    },
  ] : [])

  tags = local.tenant_tags
}

# Model Registry: DynamoDB rw on model-registry, read on experiments,
# S3 read on artifacts, KMS decrypt, CloudWatch
module "model_registry_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-model-registry"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "mlops-model-registry"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:Scan",
        "dynamodb:BatchWriteItem",
        "dynamodb:BatchGetItem",
      ]
      Resource = [
        aws_dynamodb_table.model_registry.arn,
        "${aws_dynamodb_table.model_registry.arn}/index/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:Scan",
      ]
      Resource = [
        aws_dynamodb_table.experiments.arn,
        "${aws_dynamodb_table.experiments.arn}/index/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]
      Resource = [
        local.artifacts_bucket_arn,
        "${local.artifacts_bucket_arn}/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      Resource = [aws_kms_key.this.arn]
    },
    {
      Effect = "Allow"
      Action = [
        "cloudwatch:PutMetricData",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = ["*"]
    },
  ]

  tags = local.tenant_tags
}

# MLOps API: S3 read on both, KMS decrypt, DynamoDB read on both tables,
# SQS send + get attrs, ECR describe, CloudWatch read
module "mlops_api_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-mlops-api"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "mlops-api"

  policy_statements = concat([
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]
      Resource = concat(local.all_bucket_arns, local.all_bucket_object_arns)
    },
    {
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      Resource = [aws_kms_key.this.arn]
    },
    {
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:Scan",
      ]
      Resource = [
        aws_dynamodb_table.experiments.arn,
        "${aws_dynamodb_table.experiments.arn}/index/*",
        aws_dynamodb_table.model_registry.arn,
        "${aws_dynamodb_table.model_registry.arn}/index/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:GetQueueAttributes",
      ]
      Resource = [aws_sqs_queue.training.arn]
    },
    {
      Effect = "Allow"
      Action = [
        "cloudwatch:GetMetricData",
        "cloudwatch:ListMetrics",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = ["*"]
    },
    ], var.tenant_config.ecr_enabled ? [
    {
      Effect = "Allow"
      Action = [
        "ecr:DescribeRepositories",
        "ecr:DescribeImages",
        "ecr:ListImages",
        "ecr:GetAuthorizationToken",
      ]
      Resource = [local.ecr_repo_arn]
    },
  ] : [])

  tags = local.tenant_tags
}
