################################################################################
# Pod Identity Roles for All Platform Addons
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

  # Mirrors the upstream AWS Load Balancer Controller reference IAM policy
  # (kubernetes-sigs/aws-load-balancer-controller docs/install/iam_policy.json).
  # The mutating EC2/ELB verbs are gated on the controller's own resource tag
  # (elbv2.k8s.aws/cluster) so this role can only tag, retag, modify, or delete
  # security groups, load balancers, target groups, and listeners the controller
  # itself created — never arbitrary EC2/ELB resources in the account.
  policy_statements = [
    {
      # Service-linked role creation is scoped to the ELB service (upstream
      # condition) so it can never mint an SLR for any other service.
      Effect = "Allow"
      Action = [
        "iam:CreateServiceLinkedRole",
      ]
      Resource = ["*"]
      Condition = {
        StringEquals = {
          "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
        }
      }
    },
    {
      # Read-only discovery + the AWS-integration lookups the controller resolves
      # annotations against (cognito, acm, iam server certs, waf, shield). All
      # unconditioned reads on "*" — none of these describe/associate verbs
      # support resource-level scoping.
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
        "ec2:DescribeRouteTables",
        "ec2:GetSecurityGroupsForVpc",
        "elasticloadbalancing:DescribeLoadBalancers",
        "elasticloadbalancing:DescribeLoadBalancerAttributes",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:DescribeListenerCertificates",
        "elasticloadbalancing:DescribeSSLPolicies",
        "elasticloadbalancing:DescribeRules",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:DescribeTargetGroupAttributes",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:DescribeTags",
        "elasticloadbalancing:DescribeTrustStores",
        "elasticloadbalancing:DescribeListenerAttributes",
        "elasticloadbalancing:DescribeCapacityReservation",
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
      # Creating a security group takes no resource condition (the SG does not
      # exist yet); the tag it gets stamped with is gated below.
      Effect = "Allow"
      Action = [
        "ec2:CreateSecurityGroup",
      ]
      Resource = ["*"]
    },
    {
      # Tag a security group ONLY at creation time and ONLY when the controller's
      # cluster tag is being applied.
      Effect   = "Allow"
      Action   = ["ec2:CreateTags"]
      Resource = ["arn:${local.partition}:ec2:*:*:security-group/*"]
      Condition = {
        StringEquals = {
          "ec2:CreateAction" = "CreateSecurityGroup"
        }
        Null = {
          "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
        }
      }
    },
    {
      # Retag / untag only security groups already carrying the controller's
      # cluster tag — never a security group it does not own.
      Effect   = "Allow"
      Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
      Resource = ["arn:${local.partition}:ec2:*:*:security-group/*"]
      Condition = {
        Null = {
          "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
          "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
        }
      }
    },
    {
      # Adding/removing ingress rules is unconditioned upstream — the controller
      # edits inbound rules on backend/node security groups that are tagged by
      # the cluster, not by elbv2.k8s.aws/cluster.
      Effect = "Allow"
      Action = [
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
      ]
      Resource = ["*"]
    },
    {
      # Ingress edits + deleting a security group are additionally allowed on
      # controller-owned (cluster-tagged) security groups; DeleteSecurityGroup is
      # never permitted on an untagged group.
      Effect = "Allow"
      Action = [
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:RevokeSecurityGroupIngress",
        "ec2:DeleteSecurityGroup",
      ]
      Resource = ["*"]
      Condition = {
        Null = {
          "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
        }
      }
    },
    {
      # Create a load balancer / target group only while stamping the cluster tag.
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:CreateLoadBalancer",
        "elasticloadbalancing:CreateTargetGroup",
      ]
      Resource = ["*"]
      Condition = {
        Null = {
          "aws:RequestTag/elbv2.k8s.aws/cluster" = "false"
        }
      }
    },
    {
      # Listener/rule create+delete are unconditioned upstream (children of a
      # cluster-tagged load balancer).
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:CreateRule",
        "elasticloadbalancing:DeleteRule",
      ]
      Resource = ["*"]
    },
    {
      # Retag / untag load balancers and target groups only when the cluster tag
      # is present — never resources the controller does not own.
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:RemoveTags",
      ]
      Resource = [
        "arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*",
        "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/net/*/*",
        "arn:${local.partition}:elasticloadbalancing:*:*:loadbalancer/app/*/*",
      ]
      Condition = {
        Null = {
          "aws:RequestTag/elbv2.k8s.aws/cluster"  = "true"
          "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
        }
      }
    },
    {
      # Tag listeners and listener-rules (children of tagged load balancers) —
      # unconditioned upstream.
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:AddTags",
        "elasticloadbalancing:RemoveTags",
      ]
      Resource = [
        "arn:${local.partition}:elasticloadbalancing:*:*:listener/net/*/*/*",
        "arn:${local.partition}:elasticloadbalancing:*:*:listener/app/*/*/*",
        "arn:${local.partition}:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
        "arn:${local.partition}:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
      ]
    },
    {
      # Modify / delete load balancers, target groups, and listeners only on
      # controller-owned (cluster-tagged) resources.
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:ModifyLoadBalancerAttributes",
        "elasticloadbalancing:SetIpAddressType",
        "elasticloadbalancing:SetSecurityGroups",
        "elasticloadbalancing:SetSubnets",
        "elasticloadbalancing:DeleteLoadBalancer",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:ModifyListenerAttributes",
        "elasticloadbalancing:ModifyCapacityReservation",
        "elasticloadbalancing:ModifyIpPools",
      ]
      Resource = ["*"]
      Condition = {
        Null = {
          "aws:ResourceTag/elbv2.k8s.aws/cluster" = "false"
        }
      }
    },
    {
      # Register/deregister targets against target groups.
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
      ]
      Resource = ["arn:${local.partition}:elasticloadbalancing:*:*:targetgroup/*/*"]
    },
    {
      # Listener/rule mutation + WAF association — unconditioned upstream
      # (operate on children of cluster-tagged load balancers).
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:SetWebAcl",
        "elasticloadbalancing:ModifyListener",
        "elasticloadbalancing:AddListenerCertificates",
        "elasticloadbalancing:RemoveListenerCertificates",
        "elasticloadbalancing:ModifyRule",
        "elasticloadbalancing:SetRulePriorities",
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
      # SQS event sources: receive + delete messages and read queue metadata.
      # Scoped to THIS account/region — argo-events sensors consume queues in the
      # cluster's own account, never cross-account, and never the SQS admin verbs
      # (DeleteQueue / AddPermission / SetQueueAttributes) the old sqs:* granted.
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      Resource = ["arn:${local.partition}:sqs:${var.region}:${local.account_id}:*"]
    },
    {
      # SNS event sources: subscribe/confirm the sensor's endpoint and read topic
      # metadata. Scoped to this account/region; no sns:* admin verbs (AddPermission,
      # SetTopicAttributes, DeleteTopic) on arbitrary topics.
      Effect = "Allow"
      Action = [
        "sns:Subscribe",
        "sns:Unsubscribe",
        "sns:ConfirmSubscription",
        "sns:GetTopicAttributes",
        "sns:ListSubscriptionsByTopic",
      ]
      Resource = ["arn:${local.partition}:sns:${var.region}:${local.account_id}:*"]
    },
    {
      # Wiring bucket → SQS/SNS notifications is configured on tenant buckets whose
      # names are owned by per-tenant components and not known at addon-provision
      # time, so this stays bucket-wildcard — it is notification *configuration*,
      # not object-data access.
      Effect = "Allow"
      Action = [
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
