################################################################################
# IRSA Roles for All Platform Addons
################################################################################

# cert-manager (Route53 DNS01 challenge)
module "cert_manager_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_role_prefix}-cert-manager"
  cluster_name    = var.cluster_name
  namespace       = "cert-manager"
  service_account = "cert-manager"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "route53:GetChange",
      ]
      Resource = ["arn:${local.partition}:route53:::change/*"]
    },
    {
      Effect = "Allow"
      Action = [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets",
      ]
      Resource = ["arn:${local.partition}:route53:::hostedzone/*"]
    },
    {
      Effect = "Allow"
      Action = [
        "route53:ListHostedZonesByName",
        "route53:ListHostedZones",
      ]
      Resource = ["*"]
    },
  ]

  tags = local.tags
}

# External Secrets Operator
module "external_secrets_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_role_prefix}-external-secrets"
  cluster_name    = var.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds",
      ]
      Resource = ["arn:${local.partition}:secretsmanager:${var.region}:${local.account_id}:secret:*"]
    },
    {
      Effect = "Allow"
      Action = [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath",
      ]
      Resource = ["arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter/*"]
    },
    {
      Effect = "Allow"
      Action = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]
      Resource = ["arn:${local.partition}:kms:${var.region}:${local.account_id}:key/*"]
    },
  ]

  tags = local.tags
}

# AWS Load Balancer Controller
module "alb_controller_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_role_prefix}-aws-load-balancer-controller"
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "iam:CreateServiceLinkedRole",
      ]
      Resource = ["*"]
    },
    {
      Effect = "Allow"
      Action = [
        "ec2:DescribeAccountAttributes",
        "ec2:DescribeAddresses",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeVpcs",
        "ec2:DescribeVpcPeeringConnections",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeInstances",
        "ec2:DescribeNetworkInterfaces",
        "ec2:DescribeTags",
        "ec2:DescribeCoipPools",
        "ec2:GetCoipPoolUsage",
        "ec2:DescribeTargetGroups",
        "ec2:DescribeTargetHealth",
        "ec2:DescribeListeners",
        "ec2:DescribeRules",
        "ec2:GetSecurityGroupsForVpc",
        "elasticloadbalancing:*",
        "cognito-idp:DescribeUserPoolClient",
        "acm:ListCertificates",
        "acm:DescribeCertificate",
        "iam:ListServerCertificates",
        "iam:GetServerCertificate",
        "waf-regional:GetWebACL",
        "waf-regional:GetWebACLForResource",
        "waf-regional:AssociateWebACL",
        "waf-regional:DisassociateWebACL",
        "wafv2:GetWebACL",
        "wafv2:GetWebACLForResource",
        "wafv2:AssociateWebACL",
        "wafv2:DisassociateWebACL",
        "shield:GetSubscriptionState",
        "shield:DescribeProtection",
        "shield:CreateProtection",
        "shield:DeleteProtection",
      ]
      Resource = ["*"]
    },
    {
      Effect = "Allow"
      Action = [
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:CreateTags",
        "ec2:DeleteTags",
      ]
      Resource = ["*"]
    },
  ]

  tags = local.tags
}

# External DNS
module "external_dns_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_role_prefix}-external-dns"
  cluster_name    = var.cluster_name
  namespace       = "external-dns"
  service_account = "external-dns"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "route53:ChangeResourceRecordSets",
      ]
      Resource = ["arn:${local.partition}:route53:::hostedzone/*"]
    },
    {
      Effect = "Allow"
      Action = [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets",
        "route53:ListTagsForResource",
      ]
      Resource = ["*"]
    },
  ]

  tags = local.tags
}

# Velero (conditional)
module "velero_irsa" {
  source = "../../../modules/aws/workload-identity"
  count  = var.velero_enabled ? 1 : 0

  role_name       = "${local.irsa_role_prefix}-velero"
  cluster_name    = var.cluster_name
  namespace       = "velero"
  service_account = "velero"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot",
      ]
      Resource = ["*"]
    },
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
      ]
      Resource = ["${module.velero_bucket[0].s3_bucket_arn}/*"]
    },
    {
      Effect = "Allow"
      Action = [
        "s3:ListBucket",
      ]
      Resource = [module.velero_bucket[0].s3_bucket_arn]
    },
  ]

  tags = local.tags
}

# Loki
module "loki_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_role_prefix}-loki"
  cluster_name    = var.cluster_name
  namespace       = "monitoring"
  service_account = "loki"

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
      Resource = [
        module.loki_bucket.s3_bucket_arn,
        "${module.loki_bucket.s3_bucket_arn}/*",
      ]
    },
  ]

  tags = local.tags
}

# Tempo
module "tempo_irsa" {
  source = "../../../modules/aws/workload-identity"

  role_name       = "${local.irsa_role_prefix}-tempo"
  cluster_name    = var.cluster_name
  namespace       = "monitoring"
  service_account = "tempo"

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
      Resource = [
        module.tempo_bucket.s3_bucket_arn,
        "${module.tempo_bucket.s3_bucket_arn}/*",
      ]
    },
  ]

  tags = local.tags
}

# OpenCost (conditional)
module "opencost_irsa" {
  source = "../../../modules/aws/workload-identity"
  count  = var.opencost_enabled ? 1 : 0

  role_name       = "${local.irsa_role_prefix}-opencost"
  cluster_name    = var.cluster_name
  namespace       = "opencost"
  service_account = "opencost"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
        "ec2:DescribeReservedInstances",
        "ec2:DescribeSpotPriceHistory",
        "pricing:GetProducts",
        "ce:GetCostAndUsage",
      ]
      Resource = ["*"]
    },
    {
      # Query Managed Prometheus for usage metrics (via the sigv4 proxy sidecar).
      Effect = "Allow"
      Action = [
        "aps:QueryMetrics",
        "aps:GetLabels",
        "aps:GetSeries",
        "aps:GetMetricMetadata",
      ]
      Resource = ["arn:${local.partition}:aps:${var.region}:${local.account_id}:workspace/*"]
    },
  ]

  tags = local.tags
}

# KEDA (conditional)
module "keda_irsa" {
  source = "../../../modules/aws/workload-identity"
  count  = var.keda_enabled ? 1 : 0

  role_name       = "${local.irsa_role_prefix}-keda-operator"
  cluster_name    = var.cluster_name
  namespace       = "keda"
  service_account = "keda-operator"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
        "cloudwatch:GetMetricData",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
        "kafka:DescribeCluster",
        "kafka:DescribeClusterV2",
        "kafka:GetBootstrapBrokers",
      ]
      Resource = ["*"]
    },
  ]

  tags = local.tags
}

# Argo Events (conditional)
module "argo_events_irsa" {
  source = "../../../modules/aws/workload-identity"
  count  = var.argo_events_enabled ? 1 : 0

  role_name       = "${local.irsa_role_prefix}-argo-events"
  cluster_name    = var.cluster_name
  namespace       = "argo-events"
  service_account = "argo-events-controller-manager"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "sqs:*",
        "sns:*",
        "s3:GetBucketNotification",
        "s3:PutBucketNotification",
      ]
      Resource = ["*"]
    },
  ]

  tags = local.tags
}

# Argo Workflows (conditional)
module "argo_workflows_irsa" {
  source = "../../../modules/aws/workload-identity"
  count  = var.argo_workflows_enabled ? 1 : 0

  role_name       = "${local.irsa_role_prefix}-argo-workflows"
  cluster_name    = var.cluster_name
  namespace       = "argo-workflows"
  service_account = "argo-workflows-server"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
      ]
      Resource = [
        module.argo_workflows_bucket[0].s3_bucket_arn,
        "${module.argo_workflows_bucket[0].s3_bucket_arn}/*",
      ]
    },
  ]

  tags = local.tags
}
