################################################################################
# Pod Identity Roles for Druid Components
################################################################################

locals {
  druid_namespace = "druid-${var.tenant_id}"

  s3_buckets = [
    module.deepstorage_bucket.s3_bucket_arn,
    module.indexlogs_bucket.s3_bucket_arn,
    module.msq_bucket.s3_bucket_arn,
  ]

  s3_objects = [
    "${module.deepstorage_bucket.s3_bucket_arn}/*",
    "${module.indexlogs_bucket.s3_bucket_arn}/*",
    "${module.msq_bucket.s3_bucket_arn}/*",
  ]

  s3_policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]
      Resource = concat(local.s3_buckets, local.s3_objects)
    },
  ]

  # MSK Serverless IAM auth is scoped to THIS tenant's own cluster. The serverless
  # cluster is named "${local.prefix}-msk" (see msk.tf); kafka-cluster verbs
  # authorize against cluster / topic / group resource ARNs under that name, with
  # the cluster UUID (assigned at create time) wildcarded. Every ARN carries the
  # tenant's account, region, and cluster name, so an ingestion or client pod can
  # only reach its own tenant's brokers, topics, and consumer groups.
  msk_cluster_name = "${local.prefix}-msk"
  msk_resource_arns = [
    "arn:aws:kafka:${var.region}:${var.account_id}:cluster/${local.msk_cluster_name}/*",
    "arn:aws:kafka:${var.region}:${var.account_id}:topic/${local.msk_cluster_name}/*",
    "arn:aws:kafka:${var.region}:${var.account_id}:group/${local.msk_cluster_name}/*",
  ]
}

# The ServiceAccounts the eks-gitops druid chart creates, and which pods actually run
# as. A Pod Identity association binds by (cluster, namespace, ServiceAccount NAME) —
# it does not fail when the name does not exist, it simply never attaches, and the pod
# falls back to the node role. So the names below are a contract with a chart in
# another repo, and getting one wrong is silent: the association is created, the
# console shows it, and the workload gets AccessDenied on a path nobody is watching.
#
# Source of truth: eks-gitops/catalog/druid/chart/templates/serviceaccount.yaml, whose
# `list "historical" "overlord" "broker" "msk-client"` produces these four. The pods
# map onto them non-obviously — overlord runs the ingestion path (its StatefulSet plus
# every task pod), and broker carries the query path for broker, router and
# coordinator alike — which is why the AWS role names and the ServiceAccount names are
# not the same words.
locals {
  chart_service_accounts = {
    historical = "druid-historical"
    ingestion  = "druid-overlord"
    query      = "druid-broker"
    msk_client = "druid-msk-client"
  }
}

# Historical node role (read-only S3 access)
module "historical_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-historical"
  cluster_name    = var.cluster_name
  namespace       = local.druid_namespace
  service_account = local.chart_service_accounts.historical

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetBucketLocation",
      ]
      Resource = concat(local.s3_buckets, local.s3_objects)
    },
  ]

  tags = local.tenant_tags
}

# Ingestion role (read/write S3 + MSK)
module "ingestion_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-ingestion"
  cluster_name    = var.cluster_name
  namespace       = local.druid_namespace
  service_account = local.chart_service_accounts.ingestion

  policy_statements = concat(local.s3_policy_statements, var.tenant_config.msk_enabled ? [
    {
      Effect = "Allow"
      Action = [
        "kafka-cluster:Connect",
        "kafka-cluster:DescribeTopic",
        "kafka-cluster:ReadData",
        "kafka-cluster:DescribeGroup",
        "kafka-cluster:AlterGroup",
      ]
      Resource = local.msk_resource_arns
    },
  ] : [])

  tags = local.tenant_tags
}

# Query role (read S3 + write MSQ results)
module "query_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-query"
  cluster_name    = var.cluster_name
  namespace       = local.druid_namespace
  service_account = local.chart_service_accounts.query

  policy_statements = local.s3_policy_statements

  tags = local.tenant_tags
}

# MSK client role (conditional)
module "msk_client_irsa" {
  source = "../../../../../modules/aws/workload-identity"
  count  = var.tenant_config.msk_enabled ? 1 : 0

  role_name       = "${local.prefix}-msk-client"
  cluster_name    = var.cluster_name
  namespace       = local.druid_namespace
  service_account = local.chart_service_accounts.msk_client

  policy_statements = [
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
  ]

  tags = local.tenant_tags
}
