/**
 * SES verified sending identity + configuration set.
 *
 * The verified identity is a domain (dispatch.example.com); DKIM
 * tokens published in DNS authorize SES to send on its behalf. The
 * configuration set tracks per-send events for the Grafana
 * `dispatch.email.sent` metric.
 *
 * IRSA policy in irsa.tf scopes ses:SendEmail / ses:SendRawEmail to
 * the identity ARN built from var.ses_sending_domain.
 *
 * The DNS records SES requires (3× CNAME for DKIM, optional MX for
 * MAIL FROM) are emitted as outputs; the operator publishes them in
 * the appropriate hosted zone. SES doesn't move the identity to
 * Verified until those records resolve, so the first deploy renders
 * the identity in "pending" state.
 */

resource "aws_sesv2_email_identity" "dispatch" {
  email_identity = var.ses_sending_domain

  tags = local.common_tags
}

resource "aws_sesv2_configuration_set" "dispatch" {
  configuration_set_name = "${local.prefix}-newsletter"

  delivery_options {
    tls_policy = "REQUIRE"
  }

  sending_options {
    sending_enabled = true
  }

  reputation_options {
    reputation_metrics_enabled = true
  }

  tags = local.common_tags
}
