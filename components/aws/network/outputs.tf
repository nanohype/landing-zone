output "network_mode" {
  description = "The mode this component ran in (create | adopt). Consumers derive subnet-tagging ownership from it: create stamps its own subnet tags; adopt defers tagging to the VPC owner."
  value       = var.network_mode
}

output "network" {
  description = <<-EOT
    The VPC placement facts as one coherent object, for consumers that place resources
    into this VPC (workload components such as druid and pipeline). Bundling ids,
    ownership, and AZ coverage together makes the relationship checkable at the source:
    the subnets are either built by this module (create) or asserted to reside in vpc_id
    (adopt — see adopt.tf's per-subnet postconditions), so a consumer that takes this
    object whole cannot receive a vpc_id / subnet triple that disagrees. ownership_mode is
    create when this account owns the VPC, adopt when it participates in a VPC owned by
    another account (the participant mints its own security groups; the owner runs the VPC,
    endpoints, and egress). AZ names (private_subnet_azs) are account-local — cross-account
    consumers must key on private_subnet_az_ids, which are stable across accounts. Adding a
    future network fact (an IPv6 CIDR, a per-AZ subnet map) is an additive field here, not a
    new scalar every consumer must re-wire.
  EOT
  value = {
    vpc_id                = local.resolved_vpc_id
    vpc_cidr_block        = local.resolved_vpc_cidr
    ownership_mode        = var.network_mode
    private_subnet_ids    = local.resolved_private_subnet_ids
    public_subnet_ids     = local.resolved_public_subnet_ids
    private_subnet_azs    = local.resolved_private_subnet_azs
    public_subnet_azs     = local.resolved_public_subnet_azs
    private_subnet_az_ids = local.resolved_private_subnet_az_ids
    public_subnet_az_ids  = local.resolved_public_subnet_az_ids
  }

  # At-source consistency: the AZ lists are built to parallel the subnet-id lists (element i
  # of each names subnet i's zone). A length mismatch means the object is internally
  # inconsistent before any consumer touches it — fail here, at the producer, rather than
  # letting a consumer index past the end of a shorter list.
  precondition {
    condition     = length(local.resolved_private_subnet_ids) == length(local.resolved_private_subnet_azs) && length(local.resolved_private_subnet_ids) == length(local.resolved_private_subnet_az_ids)
    error_message = "network output object is internally inconsistent: private_subnet_ids (${length(local.resolved_private_subnet_ids)}), private_subnet_azs (${length(local.resolved_private_subnet_azs)}), and private_subnet_az_ids (${length(local.resolved_private_subnet_az_ids)}) must be equal length — each AZ entry names the zone of the subnet at the same index."
  }
  precondition {
    condition     = length(local.resolved_public_subnet_ids) == length(local.resolved_public_subnet_azs) && length(local.resolved_public_subnet_ids) == length(local.resolved_public_subnet_az_ids)
    error_message = "network output object is internally inconsistent: public_subnet_ids (${length(local.resolved_public_subnet_ids)}), public_subnet_azs (${length(local.resolved_public_subnet_azs)}), and public_subnet_az_ids (${length(local.resolved_public_subnet_az_ids)}) must be equal length — each AZ entry names the zone of the subnet at the same index."
  }
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
  description = "Security group ID for the interface VPC endpoints (null in adopt mode, or when enable_interface_endpoints is false — a gateway-only VPC runs no interface endpoints and needs no SG)"
  value       = try(aws_security_group.vpc_endpoints[0].id, null)
}
