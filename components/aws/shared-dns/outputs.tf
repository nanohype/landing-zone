output "profile_id" {
  description = "The Route53 Profile ID. A consuming workload account feeds this into the private-dns component's profile_id to associate the Profile with its cluster VPC."
  value       = aws_route53profiles_profile.this.id
}

output "profile_arn" {
  description = "The Route53 Profile ARN."
  value       = aws_route53profiles_profile.this.arn
}

output "ram_share_arn" {
  description = "ARN of the RAM resource share carrying the Profile (empty when no consumers are declared)."
  value       = try(aws_ram_resource_share.profile[0].arn, "")
}

output "private_zone_ids" {
  description = "Map of private zone name to hosted zone ID."
  value = {
    for name, zone in aws_route53_zone.private : name => zone.zone_id
  }
}

output "private_zone_names" {
  description = "The private zone names this Profile carries."
  value       = var.private_zones
}
