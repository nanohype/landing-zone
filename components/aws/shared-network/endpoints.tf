# The private endpoint set an adopting EKS cluster reaches over the data path, run by the
# owner. It is the SAME module the create-mode `network` component consumes, so the VPC a
# cluster owns and the VPC a cluster adopts present the identical endpoint set — one
# definition, no drift. An adopting workload account cannot build these itself: it does not
# own the VPC, so interface-endpoint completeness is the owner's contract to keep (see
# checks.tf) — the participant's adopt preflight cannot DescribeVpcEndpoints on them.

module "eks_vpc_endpoints" {
  source = "../../../modules/aws/eks-vpc-endpoints"

  count = var.enable_vpc_endpoints ? 1 : 0

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets
  route_table_ids = flatten([
    module.vpc.private_route_table_ids,
    module.vpc.public_route_table_ids,
  ])
  security_group_id             = aws_security_group.vpc_endpoints[0].id
  environment                   = var.environment
  enable_eks_interface_endpoint = var.enable_eks_interface_endpoint
  tags                          = local.tags
}

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_vpc_endpoints ? 1 : 0

  name_prefix = "${var.environment}-shared-vpce-"
  description = "Security group for shared-VPC interface endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    # The pinned IPAM base the VPC is allocated from — the same block the subnets are
    # carved from, so the endpoint SG admits exactly the shared VPC's own address range.
    # Not the module's computed vpc_cidr_block, which is unknown until apply under IPAM.
    cidr_blocks = [local.subnet_base_cidr]
    description = "HTTPS from the shared VPC"
  }

  tags = merge(local.tags, {
    Name = "${var.environment}-shared-vpce"
  })

  lifecycle {
    create_before_destroy = true
  }
}
