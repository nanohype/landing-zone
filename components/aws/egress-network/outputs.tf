output "vpc_id" {
  description = "The ID of the egress hub VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "The dedicated CIDR block of the egress hub VPC."
  value       = var.egress_vpc_cidr
}

output "public_subnet_ids" {
  description = "Public subnet IDs — they hold the NAT gateways and the internet gateway path."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "NAT-facing private subnet IDs — the TGW attachment lives here; their default route is NAT."
  value       = module.vpc.private_subnets
}

output "nat_gateway_ids" {
  description = "NAT Gateway IDs (one shared, or one per AZ, per nat_gateways)."
  value       = module.vpc.natgw_ids
}

output "tgw_attachment_id" {
  description = "The TGW VPC attachment ID of the egress hub. Feed this into org-networking's egress_tgw_attachment_id so the TGW owner can point the static 0.0.0.0/0 route at it — a TGW participant cannot write that route itself."
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}

output "public_route_table_ids" {
  description = "Public route table IDs — they carry the spoke-supernet return route to the TGW alongside the default internet-gateway route."
  value       = module.vpc.public_route_table_ids
}

output "spoke_supernet_cidr" {
  description = "The workload supernet the public route tables return to the TGW — the exact destination the smoke test asserts a TGW-bound return route exists for."
  value       = var.spoke_supernet_cidr
}
