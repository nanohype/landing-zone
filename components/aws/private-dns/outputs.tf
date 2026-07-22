output "association_id" {
  description = "The Route53 Profile-to-VPC association ID."
  value       = aws_route53profiles_association.this.id
}

output "profile_id" {
  description = "The associated Route53 Profile ID (re-exported for downstream wiring)."
  value       = var.profile_id
}

output "vpc_id" {
  description = "The VPC the Profile was associated with."
  value       = var.vpc_id
}
