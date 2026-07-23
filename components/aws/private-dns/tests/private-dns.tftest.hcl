# Unit tests for the mode-aware private-dns component. Runs against a mocked AWS provider (no AWS
# access), so they gate the create/adopt contract:
#
#   create default     — a private zone per name, associated with this account's own VPC; no
#                        Profile association; the preflight passes when DNS resolution is enabled.
#   create multi       — the zone count tracks private_zones.
#   create dns off     — a VPC with enableDnsSupport = false fails the preflight at plan.
#   adopt default      — the shared Profile is associated with the VPC; no private zones built.
#   adopt dns off      — the preflight fails in adopt mode too.
#   mode conflicts     — create + profile_id, adopt + private_zones, create with empty zones,
#                        adopt without a valid profile_id, a bad mode, and a bad vpc id are all
#                        rejected at variable validation.

mock_provider "aws" {
  # Happy-path VPC: DNS resolution enabled. The dns-off runs override this.
  mock_data "aws_vpc" {
    defaults = {
      enable_dns_support = true
    }
  }
  # aws_route53_zone.zone_id is read by the output; give it a well-formed value.
  mock_resource "aws_route53_zone" {
    defaults = {
      zone_id = "Zmockprivate0001"
      arn     = "arn:aws:route53:::hostedzone/Zmockprivate0001"
    }
  }
}

variables {
  environment = "development"
  region      = "us-west-2"
  team        = "platform"
  vpc_id      = "vpc-00ee11ff22aa33bb4"
}

# ── create default: own private zone in own VPC; no association; preflight passes ──
run "create_default" {
  command = plan

  variables {
    private_zones = ["internal.mystartup"]
  }

  assert {
    condition     = length(aws_route53_zone.private) == 1
    error_message = "create mode must build one private zone per name"
  }
  assert {
    condition     = one(aws_route53_zone.private["internal.mystartup"].vpc).vpc_id == "vpc-00ee11ff22aa33bb4"
    error_message = "the private zone must be associated with this account's own VPC"
  }
  assert {
    condition     = length(aws_route53profiles_association.this) == 0
    error_message = "create mode must not associate a Profile"
  }
  assert {
    condition     = output.dns_mode == "create"
    error_message = "dns_mode output must report create"
  }
  assert {
    condition     = output.association_id == null
    error_message = "create mode has no Profile association"
  }
}

# ── create multi: zone count tracks the list ──
run "create_multi" {
  command = plan

  variables {
    private_zones = ["internal.mystartup", "svc.mystartup", "data.mystartup"]
  }

  assert {
    condition     = length(aws_route53_zone.private) == 3
    error_message = "zone count must track private_zones"
  }
}

# ── create + DNS off: the preflight fails at plan (inert zone) ──
run "create_dns_disabled" {
  command = plan

  variables {
    private_zones = ["internal.mystartup"]
  }

  override_data {
    target = data.aws_vpc.target
    values = {
      enable_dns_support = false
    }
  }

  expect_failures = [
    data.aws_vpc.target,
  ]
}

# ── adopt default: the shared Profile is associated; no private zones ──
run "adopt_default" {
  command = plan

  variables {
    dns_mode   = "adopt"
    profile_id = "rp-mock0000000001"
  }

  assert {
    condition     = length(aws_route53_zone.private) == 0
    error_message = "adopt mode must build no private zones"
  }
  assert {
    condition     = aws_route53profiles_association.this[0].profile_id == "rp-mock0000000001"
    error_message = "adopt mode must associate the shared Profile"
  }
  assert {
    condition     = aws_route53profiles_association.this[0].resource_id == "vpc-00ee11ff22aa33bb4"
    error_message = "adopt mode must associate the Profile with this VPC"
  }
  assert {
    condition     = output.dns_mode == "adopt"
    error_message = "dns_mode output must report adopt"
  }
}

# ── adopt + DNS off: the preflight fails in adopt mode too ──
run "adopt_dns_disabled" {
  command = plan

  variables {
    dns_mode   = "adopt"
    profile_id = "rp-mock0000000001"
  }

  override_data {
    target = data.aws_vpc.target
    values = {
      enable_dns_support = false
    }
  }

  expect_failures = [
    data.aws_vpc.target,
  ]
}

# ── mode conflict: create + a profile_id is rejected ──
run "create_rejects_profile" {
  command = plan

  variables {
    dns_mode      = "create"
    private_zones = ["internal.mystartup"]
    profile_id    = "rp-mock0000000001"
  }

  expect_failures = [
    var.profile_id,
  ]
}

# ── create with no zones is rejected (a no-op) ──
run "create_requires_zones" {
  command = plan

  variables {
    dns_mode      = "create"
    private_zones = []
  }

  expect_failures = [
    var.private_zones,
  ]
}

# ── mode conflict: adopt + private_zones is rejected ──
run "adopt_rejects_zones" {
  command = plan

  variables {
    dns_mode      = "adopt"
    profile_id    = "rp-mock0000000001"
    private_zones = ["internal.mystartup"]
  }

  expect_failures = [
    var.private_zones,
  ]
}

# ── adopt without a valid profile_id is rejected ──
run "adopt_requires_profile" {
  command = plan

  variables {
    dns_mode   = "adopt"
    profile_id = ""
  }

  expect_failures = [
    var.profile_id,
  ]
}

# ── a dns_mode outside {create, adopt} is rejected ──
run "bad_mode" {
  command = plan

  variables {
    dns_mode      = "associate"
    private_zones = ["internal.mystartup"]
  }

  expect_failures = [
    var.dns_mode,
  ]
}

# ── a malformed vpc id is rejected ──
run "bad_vpc" {
  command = plan

  variables {
    private_zones = ["internal.mystartup"]
    vpc_id        = "vpc_underscore"
  }

  expect_failures = [
    var.vpc_id,
  ]
}
