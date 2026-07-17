output "network_mode" {
  description = "The mode this component ran in (create | adopt). Consumers derive subnet-tagging ownership from it: create stamps its own subnet tags; adopt defers tagging to the VPC owner."
  value       = var.network_mode
}

output "vpc_id" {
  description = "The ID of the VPC"
  value       = local.resolved_vpc_id
}

output "vpc_cidr_block" {
  description = "The CIDR block of the VPC"
  value       = local.resolved_vpc_cidr
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = local.resolved_private_subnet_ids
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = local.resolved_public_subnet_ids
}

output "intra_subnet_ids" {
  description = "List of intra subnet IDs (empty in adopt mode — intra subnets are an owner concern)"
  value       = local.resolved_intra_subnet_ids
}

output "private_subnet_azs" {
  description = "Availability zones of the private subnets, in the same order as private_subnet_ids"
  value       = local.resolved_private_subnet_azs
}

output "public_subnet_azs" {
  description = "Availability zones of the public subnets, in the same order as public_subnet_ids"
  value       = local.resolved_public_subnet_azs
}

output "private_subnet_az_ids" {
  description = "AWS AZ IDs (e.g. usw2-az1) of the private subnets, in the same order as private_subnet_ids. AZ IDs are cross-account-stable — AZ names map to different physical zones per account — so cross-account consumers must key on these, not private_subnet_azs."
  value       = local.resolved_private_subnet_az_ids
}

output "public_subnet_az_ids" {
  description = "AWS AZ IDs (e.g. usw2-az1) of the public subnets, in the same order as public_subnet_ids. Cross-account-stable, unlike public_subnet_azs (names)."
  value       = local.resolved_public_subnet_az_ids
}

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs (empty under centralized_egress or in adopt mode)"
  value       = local.resolved_natgw_ids
}

output "private_route_table_ids" {
  description = "List of private route table IDs — not 1:1 with subnets. Create mode collapses to a single shared table when nat_gateways = 1; adopt mode resolves one table per adopted subnet, which repeats when subnets share a table. Consumers must de-duplicate before assuming a per-subnet relationship."
  value       = local.resolved_private_route_table_ids
}

output "public_route_table_ids" {
  description = "List of public route table IDs (empty in adopt mode)"
  value       = local.resolved_public_route_table_ids
}

output "vpc_endpoints_sg_id" {
  description = "Security group ID for VPC endpoints (null in adopt mode — the owner runs endpoints)"
  value       = try(aws_security_group.vpc_endpoints[0].id, null)
}
