output "dns_mode" {
  description = "The mode this component ran in (create | adopt). create owns private zones in this VPC; adopt associates a shared Profile. Tells a consumer which of the mode-specific outputs below to read."
  value       = var.dns_mode
}

output "private_zone_ids" {
  description = "Map of private zone name to hosted zone ID (create mode). Empty in adopt mode, where the zones live in the shared-dns owner behind the Profile."
  value = {
    for name, zone in aws_route53_zone.private : name => zone.zone_id
  }
}

output "association_id" {
  description = "The Route53 Profile-to-VPC association ID (adopt mode). null in create mode, which makes no association."
  value       = local.adopt_mode ? aws_route53profiles_association.this[0].id : null
}

output "profile_id" {
  description = "The associated Route53 Profile ID (adopt mode; re-exported). null in create mode."
  value       = local.adopt_mode ? var.profile_id : null
}

output "vpc_id" {
  description = "The VPC the private zones or Profile were associated with."
  value       = var.vpc_id
}
