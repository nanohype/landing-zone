# Unit tests for the private-dns participant component. Runs against a mocked AWS provider (no
# AWS access), so they gate the participant contract:
#
#   default            — the Profile is associated with the target VPC; the preflight passes
#                        when DNS resolution is enabled.
#   dns disabled       — a VPC with enableDnsSupport = false fails the preflight at plan (the
#                        association would otherwise be an inert no-op).
#   bad profile id     — a profile_id that is not an rp- id fails at variable validation.
#   bad vpc id         — a vpc_id that is not a vpc- id fails at variable validation.

mock_provider "aws" {
  # Happy-path VPC: DNS resolution enabled. The dns-disabled run overrides this.
  mock_data "aws_vpc" {
    defaults = {
      enable_dns_support = true
    }
  }
}

variables {
  environment = "development"
  region      = "us-west-2"
  team        = "platform"
  profile_id  = "rp-mock0000000001"
  vpc_id      = "vpc-00ee11ff22aa33bb4"
}

# ── default: the Profile is associated with the VPC; preflight passes ──
run "default" {
  command = plan

  assert {
    condition     = aws_route53profiles_association.this.profile_id == "rp-mock0000000001"
    error_message = "the association must target the shared Profile"
  }
  assert {
    condition     = aws_route53profiles_association.this.resource_id == "vpc-00ee11ff22aa33bb4"
    error_message = "the association must target the cluster VPC"
  }
}

# ── dns disabled: an inert association is caught at plan, not after apply ──
run "dns_disabled" {
  command = plan

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

# ── bad profile id: rejected at variable validation ──
run "bad_profile_id" {
  command = plan

  variables {
    profile_id = "profile-123"
  }

  expect_failures = [
    var.profile_id,
  ]
}

# ── bad vpc id: rejected at variable validation ──
run "bad_vpc_id" {
  command = plan

  variables {
    vpc_id = "vpc_underscore"
  }

  expect_failures = [
    var.vpc_id,
  ]
}
