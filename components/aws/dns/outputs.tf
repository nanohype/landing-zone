output "dns_mode" {
  description = "The mode this component ran in (create | adopt). create owns the zone; adopt references a zone owned elsewhere and re-exports it."
  value       = var.dns_mode
}

output "hosted_zone_id" {
  description = "The ID of the primary hosted zone — built in create mode, resolved from adopt_zone_id in adopt mode. Always a real zone id; never empty."
  value       = local.resolved_zone_id
}

output "hosted_zone_name_servers" {
  description = "Name servers for the primary hosted zone (use for domain delegation). Resolves in both modes."
  value       = local.resolved_zone_name_servers
}

output "subdomain_zone_ids" {
  description = "Map of subdomain prefix to hosted zone ID (create mode only; empty in adopt mode, which owns no subdomains)."
  value = {
    for prefix, zone in aws_route53_zone.subdomains : prefix => zone.zone_id
  }
}

output "subdomain_name_servers" {
  description = "Map of subdomain prefix to name servers (create mode only)."
  value = {
    for prefix, zone in aws_route53_zone.subdomains : prefix => zone.name_servers
  }
}

output "acm_certificate_arns" {
  description = "Map of certificate key to ACM certificate ARN (create mode only; adopt mode issues no certificates)."
  value = {
    for k, cert in aws_acm_certificate.this : k => cert.arn
  }
}

output "domain_name" {
  description = "The primary domain name"
  value       = var.domain_name
}
