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

output "nat_gateway_ids" {
  description = "List of NAT Gateway IDs (empty under centralized_egress or in adopt mode)"
  value       = local.resolved_natgw_ids
}

output "private_route_table_ids" {
  description = "List of private route table IDs (one per private subnet)"
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
