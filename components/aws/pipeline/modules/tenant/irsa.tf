################################################################################
# IRSA Roles for Pipeline Components
################################################################################

locals {
  irsa_prefix = "${var.environment}-pipeline-${var.tenant_id}"

  all_bucket_arns = [
    module.raw_bucket.s3_bucket_arn,
    module.staging_bucket.s3_bucket_arn,
    module.curated_bucket.s3_bucket_arn,
  ]

  all_bucket_objects = [
    "${module.raw_bucket.s3_bucket_arn}/*",
    "${module.staging_bucket.s3_bucket_arn}/*",
    "${module.curated_bucket.s3_bucket_arn}/*",
  ]
}

################################################################################
# Worker — S3 rw all 3 buckets, KMS encrypt/decrypt, Glue catalog rw, CloudWatch
################################################################################

module "worker_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_prefix}-worker"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "pipeline-worker"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]
      Resource = concat(local.all_bucket_arns, local.all_bucket_objects)
    },
    {
      Effect = "Allow"
      Action = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
      ]
      Resource = [aws_kms_key.datalake.arn]
    },
    {
      Effect = "Allow"
      Action = [
        "glue:GetDatabase",
        "glue:GetDatabases",
        "glue:GetTable",
        "glue:GetTables",
        "glue:CreateTable",
        "glue:UpdateTable",
        "glue:DeleteTable",
        "glue:GetPartition",
        "glue:GetPartitions",
        "glue:CreatePartition",
        "glue:BatchCreatePartition",
        "glue:UpdatePartition",
        "glue:DeletePartition",
      ]
      Resource = ["*"]
    },
    {
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = ["*"]
    },
  ]

  tags = local.tenant_tags
}

################################################################################
# Orchestrator — SFN execute, Batch submit, CloudWatch
################################################################################

module "orchestrator_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_prefix}-orchestrator"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "pipeline-orchestrator"

  policy_statements = concat(
    var.tenant_config.step_functions_enabled ? [
      {
        Effect = "Allow"
        Action = [
          "states:StartExecution",
          "states:StopExecution",
          "states:DescribeExecution",
          "states:ListExecutions",
        ]
        Resource = [aws_sfn_state_machine.this[0].arn]
      },
    ] : [],
    var.tenant_config.batch_enabled ? [
      {
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:DescribeJobs",
          "batch:ListJobs",
          "batch:TerminateJob",
        ]
        Resource = ["*"]
      },
    ] : [],
    [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = ["*"]
      },
    ],
  )

  tags = local.tenant_tags
}

################################################################################
# Connector — S3 PutObject raw only, KMS encrypt, MSK IAM auth, CloudWatch
################################################################################

module "connector_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_prefix}-connector"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "pipeline-connector"

  policy_statements = concat(
    [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
        ]
        Resource = [
          module.raw_bucket.s3_bucket_arn,
          "${module.raw_bucket.s3_bucket_arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey",
        ]
        Resource = [aws_kms_key.datalake.arn]
      },
    ],
    var.tenant_config.msk_enabled ? [
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup",
        ]
        Resource = ["*"]
      },
    ] : [],
    [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
        ]
        Resource = ["*"]
      },
    ],
  )

  tags = local.tenant_tags
}
