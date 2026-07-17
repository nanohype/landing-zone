output "vpc_id" {
  description = "The ID of the shared VPC. A consuming workload account feeds this into the network component's adopt_vpc_id."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "The IPAM-allocated CIDR block of the shared VPC"
  value       = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs — the always-shared tier. A consuming account feeds these into the network component's adopt_private_subnet_ids."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs — shared only when share_public_subnets is set. A consuming account feeds these into adopt_public_subnet_ids for internet-facing load balancers."
  value       = module.vpc.public_subnets
}

output "intra_subnet_ids" {
  description = "Intra subnet IDs — owner-internal, never shared."
  value       = module.vpc.intra_subnets
}

output "private_subnet_azs" {
  description = "Availability zone NAMES of the private subnets, in the same order as private_subnet_ids. Same-account readability only — names map to different physical zones per account, so cross-account consumers must use private_subnet_az_ids."
  value       = local.azs
}

output "private_subnet_az_ids" {
  description = "AWS AZ IDs (e.g. usw2-az1) of the private subnets, in the same order as private_subnet_ids. Cross-account-stable — this is the field a consumer keys on, not private_subnet_azs (names)."
  value       = local.az_ids
}

output "public_subnet_az_ids" {
  description = "AWS AZ IDs (e.g. usw2-az1) of the public subnets, in the same order as public_subnet_ids. Cross-account-stable, unlike the AZ names."
  value       = local.az_ids
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs (empty under centralized_egress)."
  value       = module.vpc.natgw_ids
}

output "private_route_table_ids" {
  description = "Private route table IDs — not 1:1 with subnets (they collapse to a shared table when nat_gateways = 1). Consumers must de-duplicate before assuming a per-subnet relationship."
  value       = module.vpc.private_route_table_ids
}

output "ipam_pool_id" {
  description = "The IPAM pool the shared VPC CIDR was drawn from (the explicit override, or the tag-discovered org env sub-pool)."
  value       = local.ipam_pool_id
}

output "ram_share_arn" {
  description = "ARN of the RAM resource share carrying the shared subnets (null when consumer_account_ids is empty)."
  value       = try(aws_ram_resource_share.subnets[0].arn, null)
}

output "consumer_account_ids" {
  description = "The workload account IDs the shared subnets are RAM-shared to."
  value       = var.consumer_account_ids
}

output "subnet_role_tags" {
  description = "The ELB role tags stamped on the shared subnets. Deliberately carries no kubernetes.io/cluster/<cluster> ownership tag — a shared VPC is bound to no single cluster, and cross-account consumers select subnets by explicit ID."
  value = {
    public  = local.public_subnet_role_tags
    private = local.private_subnet_role_tags
  }
}

output "vpc_endpoints_sg_id" {
  description = "Security group ID for the shared-VPC interface endpoints (null when enable_vpc_endpoints is false)."
  value       = try(aws_security_group.vpc_endpoints[0].id, null)
}
