data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.max_azs)

  tags = merge(var.tags, {
    Component = "network"
    Team      = var.team
  })
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.environment}-vpc"
  cidr = var.vpc_cidr
  azs  = local.azs

  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  intra_subnets   = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 20)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.nat_gateways == 1
  one_nat_gateway_per_az = var.nat_gateways >= var.max_azs

  enable_dns_hostnames = true
  enable_dns_support   = true

  # EKS subnet tags
  # Cluster-ownership + Karpenter-discovery tags are per-cluster and applied by the
  # cluster component (aws_ec2_tag), not here — the VPC is shared per environment and
  # cluster-agnostic, so co-located sibling clusters each stamp their own tags.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = local.tags
}

################################################################################
# VPC Endpoints
################################################################################

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id = module.vpc.vpc_id

  endpoints = merge({
    s3 = {
      service      = "s3"
      service_type = "Gateway"
      route_table_ids = flatten([
        module.vpc.private_route_table_ids,
        module.vpc.public_route_table_ids,
      ])
      tags = { Name = "${var.environment}-s3-endpoint" }
    }
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
      tags                = { Name = "${var.environment}-ecr-api-endpoint" }
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
      tags                = { Name = "${var.environment}-ecr-dkr-endpoint" }
    }
    secretsmanager = {
      service             = "secretsmanager"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
      tags                = { Name = "${var.environment}-secretsmanager-endpoint" }
    }
    ssm = {
      service             = "ssm"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
      tags                = { Name = "${var.environment}-ssm-endpoint" }
    }
    sts = {
      service             = "sts"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
      tags                = { Name = "${var.environment}-sts-endpoint" }
    }
    # eks-auth stays unconditional: it serves eks-auth.<region>.amazonaws.com (EKS Pod
    # Identity), a SIBLING of eks.<region>.amazonaws.com — not a parent of the OIDC
    # issuer — so its private DNS doesn't shadow oidc.eks.<region>. Don't conditionalize it.
    eks_auth = {
      service             = "eks-auth"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
      tags                = { Name = "${var.environment}-eks-auth-endpoint" }
    }
    # Amazon Managed Prometheus data plane — aps-workspaces.<region>.amazonaws.com,
    # used for BOTH alloy's remote_write and opencost's sigv4-proxied queries.
    #
    # Without it, aps-workspaces has no private DNS inside the VPC while every other
    # AWS service the platform touches does, so those two callers fall off the
    # endpoint path and depend on public resolution + NAT egress. Observed on a live
    # cluster as `dial tcp: lookup aps-workspaces.us-west-2.amazonaws.com: i/o
    # timeout` — opencost crashlooping and alloy unable to ship metrics at all.
    #
    # A private endpoint also removes the NAT data-processing charge on a metrics
    # stream that runs 24/7, so it is cheaper than the alternative, not just correct.
    aps_workspaces = {
      service             = "aps-workspaces"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
      tags                = { Name = "${var.environment}-aps-workspaces-endpoint" }
    }
    # The EKS API interface endpoint is conditional: its private DNS shadows the
    # OIDC issuer subdomain (oidc.eks.<region>.amazonaws.com), which a provisioning
    # hub must resolve from inside the VPC. See var.enable_eks_interface_endpoint.
    }, var.enable_eks_interface_endpoint ? {
    eks = {
      service             = "eks"
      private_dns_enabled = true
      subnet_ids          = module.vpc.private_subnets
      security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
      tags                = { Name = "${var.environment}-eks-endpoint" }
    }
  } : {})

  tags = local.tags
}

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  name_prefix = "${var.environment}-vpc-endpoints-"
  description = "Security group for VPC endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from VPC"
  }

  tags = merge(local.tags, {
    Name = "${var.environment}-vpc-endpoints"
  })

  lifecycle {
    create_before_destroy = true
  }
}

################################################################################
# VPC Flow Logs
################################################################################

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  iam_role_arn    = aws_iam_role.flow_logs[0].arn
  log_destination = aws_cloudwatch_log_group.flow_logs[0].arn
  traffic_type    = "ALL"
  vpc_id          = module.vpc.vpc_id

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc-flow-logs/${var.environment}"
  retention_in_days = 30

  tags = local.tags
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.environment}-vpc-flow-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name = "${var.environment}-vpc-flow-logs"
  role = aws_iam_role.flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}
