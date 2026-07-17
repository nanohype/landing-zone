data "aws_caller_identity" "current" {}

locals {
  tags = merge(var.tags, {
    Component = "dns"
    Team      = var.team
  })

  # Flatten ACM certificate domain validation options for Route53 record creation
  cert_validation_records = merge([
    for cert_key, cert in aws_acm_certificate.this : {
      for dvo in cert.domain_validation_options : "${cert_key}-${dvo.domain_name}" => {
        name    = dvo.resource_record_name
        record  = dvo.resource_record_value
        type    = dvo.resource_record_type
        zone_id = aws_route53_zone.primary[0].zone_id
      }
    }
  ]...)
}

################################################################################
# Primary Hosted Zone
################################################################################

resource "aws_route53_zone" "primary" {
  count = var.create_hosted_zone ? 1 : 0

  name    = var.domain_name
  comment = "${var.environment} primary hosted zone"

  tags = merge(local.tags, {
    Name = var.domain_name
  })
}

################################################################################
# Subdomain Hosted Zones
################################################################################

resource "aws_route53_zone" "subdomains" {
  for_each = var.create_hosted_zone ? toset(var.subdomain_prefixes) : toset([])

  name    = "${each.value}.${var.domain_name}"
  comment = "${var.environment} subdomain zone for ${each.value}"

  tags = merge(local.tags, {
    Name = "${each.value}.${var.domain_name}"
  })
}

resource "aws_route53_record" "subdomain_delegation" {
  for_each = var.create_hosted_zone ? toset(var.subdomain_prefixes) : toset([])

  zone_id = aws_route53_zone.primary[0].zone_id
  name    = "${each.value}.${var.domain_name}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.subdomains[each.value].name_servers
}

################################################################################
# ACM Certificates
################################################################################

resource "aws_acm_certificate" "this" {
  for_each = var.acm_certificates

  domain_name               = each.value.domain_name
  subject_alternative_names = each.value.subject_alternative_names
  validation_method         = "DNS"

  tags = merge(local.tags, {
    Name = each.key
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.create_hosted_zone ? local.cert_validation_records : {}

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = each.value.zone_id
}

resource "aws_acm_certificate_validation" "this" {
  for_each = {
    for k, v in var.acm_certificates : k => v
    if v.wait_for_validation && var.create_hosted_zone
  }

  certificate_arn = aws_acm_certificate.this[each.key].arn
  validation_record_fqdns = [
    for dvo in aws_acm_certificate.this[each.key].domain_validation_options :
    aws_route53_record.cert_validation["${each.key}-${dvo.domain_name}"].fqdn
  ]
}

################################################################################
# DNSSEC
################################################################################

resource "aws_kms_key" "dnssec" {
  count = var.enable_dnssec && var.create_hosted_zone ? 1 : 0

  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7
  key_usage                = "SIGN_VERIFY"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableIAMPolicies"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowRoute53DNSSEC"
        Effect = "Allow"
        Principal = {
          Service = "dnssec-route53.amazonaws.com"
        }
        Action = [
          "kms:DescribeKey",
          "kms:GetPublicKey",
          "kms:Sign",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })

  tags = merge(local.tags, {
    Name = "${var.environment}-dnssec"
  })
}

resource "aws_route53_key_signing_key" "this" {
  count = var.enable_dnssec && var.create_hosted_zone ? 1 : 0

  hosted_zone_id             = aws_route53_zone.primary[0].id
  key_management_service_arn = aws_kms_key.dnssec[0].arn
  name                       = "${var.environment}-dnssec"
}

resource "aws_route53_hosted_zone_dnssec" "this" {
  count = var.enable_dnssec && var.create_hosted_zone ? 1 : 0

  hosted_zone_id = aws_route53_zone.primary[0].id

  depends_on = [aws_route53_key_signing_key.this]
}

################################################################################
# external-dns domain filter
#
# Publish this environment's primary domain to SSM so cluster-bootstrap can stamp
# it onto the ArgoCD cluster Secret as the `external-dns/domain-filter`
# annotation, where the addons-external-dns ApplicationSet reads it to confine
# external-dns to this environment's Route53 zone (paired with a per-cluster
# txtOwnerId, so clusters sharing a zone never delete each other's records).
#
# Keyed on the environment, not a cluster name: dns is a per-environment
# component that owns one primary zone and carries no cluster identity, so the
# environment is its natural key — matching how cluster-bootstrap reads it back.
# Published to SSM (not a terragrunt output) because cluster-bootstrap also runs
# under the fleet-vend provider-opentofu path, which resolves cross-component
# values through SSM rather than the terragrunt dependency graph.
resource "aws_ssm_parameter" "external_dns_domain_filter" {
  name  = "/eks-agent-platform/${var.environment}/dns/domain_filter"
  type  = "String"
  value = var.domain_name

  tags = local.tags
}
