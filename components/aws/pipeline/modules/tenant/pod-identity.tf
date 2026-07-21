################################################################################
# Pod Identity Roles for Pipeline Components
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

  # Glue authorizes catalog operations against the catalog + database + table
  # ARNs together, so the worker grant names all three — scoped to THIS tenant's
  # database only, mirroring how the bucket/KMS statements above scope to the
  # tenant's own resources.
  glue_catalog_arns = [
    "arn:aws:glue:${var.region}:${var.account_id}:catalog",
    aws_glue_catalog_database.this.arn,
    "arn:aws:glue:${var.region}:${var.account_id}:table/${aws_glue_catalog_database.this.name}/*",
  ]

  # MSK Serverless IAM auth is scoped to THIS tenant's own cluster. The serverless
  # cluster is named local.irsa_prefix (see msk.tf: cluster_name = local.prefix,
  # the same tenant-qualified string). kafka-cluster verbs authorize against
  # cluster / topic / group resource ARNs under that name; the cluster UUID is
  # assigned by MSK at create time, so it is wildcarded. Every ARN carries the
  # tenant's account, region, and cluster name, so a connector can only reach its
  # own tenant's brokers, topics, and consumer groups — never another tenant's.
  msk_resource_arns = [
    "arn:aws:kafka:${var.region}:${var.account_id}:cluster/${local.irsa_prefix}/*",
    "arn:aws:kafka:${var.region}:${var.account_id}:topic/${local.irsa_prefix}/*",
    "arn:aws:kafka:${var.region}:${var.account_id}:group/${local.irsa_prefix}/*",
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
      Resource = local.glue_catalog_arns
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
        Resource = local.msk_resource_arns
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
