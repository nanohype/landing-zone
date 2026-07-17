# The private endpoint set every EKS VPC on the platform needs: an S3 gateway
# endpoint plus the interface endpoints for the AWS services the cluster and its
# addons call over the data path. Both the create-mode `network` component and the
# `shared-network` owner component consume this module, so the endpoint set is
# defined once and never drifts between the VPC a cluster owns and the VPC a cluster
# adopts.
#
# The security group is owned by the caller (it scopes 443 to the caller's VPC CIDR)
# and passed in — the module only wires it onto the interface endpoints.

module "endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  vpc_id = var.vpc_id

  endpoints = merge({
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = var.route_table_ids
      tags            = { Name = "${var.environment}-s3-endpoint" }
    }
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      subnet_ids          = var.private_subnet_ids
      security_group_ids  = [var.security_group_id]
      tags                = { Name = "${var.environment}-ecr-api-endpoint" }
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      subnet_ids          = var.private_subnet_ids
      security_group_ids  = [var.security_group_id]
      tags                = { Name = "${var.environment}-ecr-dkr-endpoint" }
    }
    secretsmanager = {
      service             = "secretsmanager"
      private_dns_enabled = true
      subnet_ids          = var.private_subnet_ids
      security_group_ids  = [var.security_group_id]
      tags                = { Name = "${var.environment}-secretsmanager-endpoint" }
    }
    ssm = {
      service             = "ssm"
      private_dns_enabled = true
      subnet_ids          = var.private_subnet_ids
      security_group_ids  = [var.security_group_id]
      tags                = { Name = "${var.environment}-ssm-endpoint" }
    }
    sts = {
      service             = "sts"
      private_dns_enabled = true
      subnet_ids          = var.private_subnet_ids
      security_group_ids  = [var.security_group_id]
      tags                = { Name = "${var.environment}-sts-endpoint" }
    }
    # eks-auth stays unconditional: it serves eks-auth.<region>.amazonaws.com (EKS Pod
    # Identity), a SIBLING of eks.<region>.amazonaws.com — not a parent of the OIDC
    # issuer — so its private DNS doesn't shadow oidc.eks.<region>. Don't conditionalize it.
    eks_auth = {
      service             = "eks-auth"
      private_dns_enabled = true
      subnet_ids          = var.private_subnet_ids
      security_group_ids  = [var.security_group_id]
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
      subnet_ids          = var.private_subnet_ids
      security_group_ids  = [var.security_group_id]
      tags                = { Name = "${var.environment}-aps-workspaces-endpoint" }
    }
    # The EKS API interface endpoint is conditional: its private DNS shadows the
    # OIDC issuer subdomain (oidc.eks.<region>.amazonaws.com), which a provisioning
    # hub must resolve from inside the VPC. See var.enable_eks_interface_endpoint.
    }, var.enable_eks_interface_endpoint ? {
    eks = {
      service             = "eks"
      private_dns_enabled = true
      subnet_ids          = var.private_subnet_ids
      security_group_ids  = [var.security_group_id]
      tags                = { Name = "${var.environment}-eks-endpoint" }
    }
  } : {})

  tags = var.tags
}
