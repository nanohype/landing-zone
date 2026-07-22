# Unit tests for the mode-aware dns component. Runs against a mocked AWS provider (no AWS
# access), so they gate the create/adopt behavior contract:
#
#   create default    — the primary zone is built; no subdomains, certs, or DNSSEC; the
#                        zone id resolves from the built zone, not the adopt data source.
#   create subdomains  — a subdomain zone and its NS delegation record are planned per prefix.
#   create dnssec      — the signing KMS key, key-signing key, and zone DNSSEC are planned.
#   create acm         — the certificate, its validation records, and the validation wait
#                        are planned against the primary zone.
#   adopt happy        — nothing is built (no primary zone, no certs, no DNSSEC); the zone id
#                        and name servers resolve from the adopt data source; preflight passes.
#   adopt wrong zone   — an adopt_zone_id resolving to a zone whose name != domain_name fails
#                        the plan at the data-source postcondition, not silently downstream.
#   mode conflicts     — adopt + a create-mode lever (subdomains / dnssec / acm), create +
#                        adopt_zone_id, and adopt without adopt_zone_id are all rejected at
#                        variable validation, not silently ignored.
#   bad mode           — a dns_mode outside {create, adopt} is rejected at variable validation.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }
  # Happy-path adopt default: the resolved zone's name matches domain_name (with the trailing
  # dot Route53 returns). The wrong-zone run overrides this to inject the contract violation.
  mock_data "aws_route53_zone" {
    defaults = {
      name         = "example.com."
      name_servers = ["ns-1.mock.example", "ns-2.mock.example"]
    }
  }
  # aws_route53_key_signing_key validates the KMS ARN format at plan; the mock's random string
  # is not a valid ARN, so pin a well-formed one for the DNSSEC path.
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-west-2:111111111111:key/mock-dnssec-0000-0000-000000000000"
    }
  }
  # domain_validation_options is computed; the mock leaves it empty, so the validation-record
  # for_each would flatten to nothing. Populate it so the ACM validation path is exercised.
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-west-2:111111111111:certificate/mock-cert-0000-0000-000000000000"
      domain_validation_options = [
        {
          domain_name           = "app.example.com"
          resource_record_name  = "_mock.app.example.com."
          resource_record_value = "_mockval.acm-validations.aws."
          resource_record_type  = "CNAME"
        },
      ]
    }
  }
}

variables {
  environment = "development"
  region      = "us-west-2"
  domain_name = "example.com"
  team        = "platform"
}

# ── create default: the zone is built; no optional resources; id resolves from the zone ──
run "create_default" {
  command = plan

  assert {
    condition     = length(aws_route53_zone.primary) == 1
    error_message = "create mode must build the primary hosted zone"
  }
  assert {
    condition     = length(data.aws_route53_zone.adopt) == 0
    error_message = "create mode must not read the adopt data source"
  }
  assert {
    condition     = length(aws_route53_zone.subdomains) == 0
    error_message = "no subdomain zones without subdomain_prefixes"
  }
  assert {
    condition     = length(aws_acm_certificate.this) == 0
    error_message = "no certificates without acm_certificates"
  }
  assert {
    condition     = length(aws_kms_key.dnssec) == 0
    error_message = "DNSSEC is off by default — no signing key"
  }
  assert {
    condition     = output.dns_mode == "create"
    error_message = "dns_mode output must report the mode the component ran in"
  }
}

# ── create + subdomains: a zone and an NS delegation record per prefix ──
run "create_subdomains" {
  command = plan

  variables {
    subdomain_prefixes = ["api", "app"]
  }

  assert {
    condition     = length(aws_route53_zone.subdomains) == 2
    error_message = "create mode must build one zone per subdomain prefix"
  }
  assert {
    condition     = length(aws_route53_record.subdomain_delegation) == 2
    error_message = "create mode must delegate each subdomain from the primary with an NS record"
  }
}

# ── create + DNSSEC: signing key, key-signing key, and zone DNSSEC ──
run "create_dnssec" {
  command = plan

  variables {
    enable_dnssec = true
  }

  assert {
    condition     = length(aws_kms_key.dnssec) == 1
    error_message = "enable_dnssec must provision the ECC signing KMS key"
  }
  assert {
    condition     = length(aws_route53_key_signing_key.this) == 1
    error_message = "enable_dnssec must provision the key-signing key"
  }
  assert {
    condition     = length(aws_route53_hosted_zone_dnssec.this) == 1
    error_message = "enable_dnssec must enable zone DNSSEC"
  }
}

# ── create + ACM: certificate, validation records, and the validation wait ──
run "create_acm" {
  command = plan

  variables {
    acm_certificates = {
      web = {
        domain_name               = "app.example.com"
        subject_alternative_names = ["www.example.com"]
      }
    }
  }

  assert {
    condition     = length(aws_acm_certificate.this) == 1
    error_message = "acm_certificates must plan the certificate"
  }
  assert {
    condition     = length(aws_route53_record.cert_validation) > 0
    error_message = "create mode must write DNS validation records for the certificate"
  }
  assert {
    condition     = length(aws_acm_certificate_validation.this) == 1
    error_message = "a wait_for_validation certificate must plan the validation wait in create mode"
  }
}

# ── adopt happy path: nothing built; outputs resolve from the data source; preflight passes ──
run "adopt_happy" {
  command = plan

  variables {
    dns_mode      = "adopt"
    adopt_zone_id = "Zmockadopt00001"
  }

  assert {
    condition     = length(aws_route53_zone.primary) == 0
    error_message = "adopt mode must not build a primary zone"
  }
  assert {
    condition     = length(data.aws_route53_zone.adopt) == 1
    error_message = "adopt mode must resolve the zone from the data source"
  }
  assert {
    condition     = length(aws_acm_certificate.this) == 0
    error_message = "adopt mode issues no certificates"
  }
  assert {
    condition     = length(aws_kms_key.dnssec) == 0
    error_message = "adopt mode signs no zone"
  }
  assert {
    condition     = output.hosted_zone_id == "Zmockadopt00001"
    error_message = "adopt mode must re-export the resolved zone id through the same output"
  }
  assert {
    condition     = output.dns_mode == "adopt"
    error_message = "dns_mode output must report adopt"
  }
}

# ── adopt failure: an adopt_zone_id pointing at the wrong zone fails the preflight ──
run "adopt_wrong_zone" {
  command = plan

  variables {
    dns_mode      = "adopt"
    adopt_zone_id = "Zmockadopt00001"
  }

  override_data {
    target = data.aws_route53_zone.adopt
    values = {
      name         = "someone-elses-domain.net."
      name_servers = ["ns-1.mock.example", "ns-2.mock.example"]
    }
  }

  expect_failures = [
    data.aws_route53_zone.adopt,
  ]
}

# ── mode conflict: adopt + a create-mode subdomain lever is rejected, not ignored ──
run "adopt_rejects_subdomains" {
  command = plan

  variables {
    dns_mode           = "adopt"
    adopt_zone_id      = "Zmockadopt00001"
    subdomain_prefixes = ["api"]
  }

  expect_failures = [
    var.subdomain_prefixes,
  ]
}

# ── mode conflict: adopt + DNSSEC is rejected ──
run "adopt_rejects_dnssec" {
  command = plan

  variables {
    dns_mode      = "adopt"
    adopt_zone_id = "Zmockadopt00001"
    enable_dnssec = true
  }

  expect_failures = [
    var.enable_dnssec,
  ]
}

# ── mode conflict: adopt + ACM issuance is rejected ──
run "adopt_rejects_acm" {
  command = plan

  variables {
    dns_mode      = "adopt"
    adopt_zone_id = "Zmockadopt00001"
    acm_certificates = {
      web = { domain_name = "app.example.com" }
    }
  }

  expect_failures = [
    var.acm_certificates,
  ]
}

# ── mode conflict: create + an adopt_zone_id is rejected ──
run "create_rejects_adopt_zone" {
  command = plan

  variables {
    dns_mode      = "create"
    adopt_zone_id = "Zmockadopt00001"
  }

  expect_failures = [
    var.adopt_zone_id,
  ]
}

# ── adopt without adopt_zone_id fails at variable validation, not at the data source ──
run "adopt_requires_zone_id" {
  command = plan

  variables {
    dns_mode      = "adopt"
    adopt_zone_id = ""
  }

  expect_failures = [
    var.adopt_zone_id,
  ]
}

# ── a dns_mode outside {create, adopt} is rejected ──
run "bad_mode" {
  command = plan

  variables {
    dns_mode = "import"
  }

  expect_failures = [
    var.dns_mode,
  ]
}
