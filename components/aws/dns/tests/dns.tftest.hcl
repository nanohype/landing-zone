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
#   zone tag limit     — every hosted zone carries at most 10 tags (Route 53's
#                        ChangeTagsForResource limit) under the real root default_tags, and
#                        one tag more fails the plan at the zone's precondition.

mock_provider "aws" {
  # The default_tags live/root.hcl generates into every leaf's provider, as the provider
  # reports them through aws_default_tags. Eleven keys: on their own one more than a
  # Route 53 hosted zone accepts.
  mock_data "aws_default_tags" {
    defaults = {
      tags = {
        Environment        = "development"
        ManagedBy          = "opentofu"
        Project            = "landing-zone"
        CostCenter         = "platform-engineering"
        BusinessUnit       = "engineering"
        DataClassification = "internal"
        Compliance         = "soc2"
        Repository         = "nanohype/landing-zone"
        Owner              = "platform-engineering"
        Revision           = "local"
        Lifecycle          = "persistent"
      }
    }
  }
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
      arn = "arn:aws:kms:us-east-1:111111111111:key/mock-dnssec-0000-0000-000000000000"
    }
  }
  # domain_validation_options is computed; the mock leaves it empty, so the validation-record
  # for_each would flatten to nothing. Populate it so the ACM validation path is exercised.
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:us-east-1:111111111111:certificate/mock-cert-0000-0000-000000000000"
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

# Hosted zones are created through the default_tags-free provider in route53-tags.tf.
mock_provider "aws" {
  alias = "route53"
}

variables {
  environment = "development"
  region      = "us-east-1"
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

# ── zone tag limit: the root default_tags plus the component's tags fit in one Route 53 call ──
#
# ChangeTagsForResource takes at most 10 tags, and the provider sends a zone's whole set in
# one call. Before route53-tags.tf the primary zone carried the 11 default tags plus
# Component, Team and Name: 14, refused by Route 53 on create.
run "zone_tags_within_route53_limit" {
  command = plan

  variables {
    subdomain_prefixes = ["api"]
  }

  assert {
    condition     = alltrue([for z in concat(aws_route53_zone.primary, values(aws_route53_zone.subdomains)) : length(z.tags) <= 10])
    error_message = "every hosted zone must carry at most 10 tags, the most one Route 53 ChangeTagsForResource call accepts"
  }
  assert {
    condition = alltrue([
      for k in ["Environment", "ManagedBy", "CostCenter", "BusinessUnit", "DataClassification", "Team"] :
      contains(keys(aws_route53_zone.primary[0].tags), k)
    ])
    error_message = "the hosted zone must keep every key the org-compliance required-tags rule checks"
  }
  assert {
    condition     = !contains(keys(aws_route53_zone.primary[0].tags), "Revision")
    error_message = "the per-commit Revision tag must stay off hosted zones"
  }
}

# ── one tag over the limit fails the plan, not the CreateHostedZone that follows it ──
run "zone_tags_over_route53_limit_fail_the_plan" {
  command = plan

  variables {
    tags = { CostAllocation = "shared" }
  }

  expect_failures = [
    aws_route53_zone.primary,
  ]
}

# ── the provider's own count: a default tag set reaching the zone is caught too ──
#
# The provider sends tags_all, not tags. Were default_tags ever added to the route53
# provider, tags would still fit while tags_all did not; the postcondition reads tags_all.
# The override stands in for the provider computing tags_all from the root default_tags.
run "zone_tags_all_over_route53_limit_fail_the_plan" {
  command = plan

  override_resource {
    target = aws_route53_zone.primary
    values = {
      tags_all = {
        Environment        = "development"
        ManagedBy          = "opentofu"
        Project            = "landing-zone"
        CostCenter         = "platform-engineering"
        BusinessUnit       = "engineering"
        DataClassification = "internal"
        Compliance         = "soc2"
        Repository         = "nanohype/landing-zone"
        Owner              = "platform-engineering"
        Revision           = "local"
        Lifecycle          = "persistent"
      }
    }
  }

  expect_failures = [
    aws_route53_zone.primary,
  ]
}
