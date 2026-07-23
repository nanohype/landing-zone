# Unit tests for the shared-dns owner component. Runs against a mocked AWS provider (no AWS
# access), so they gate the owner contract:
#
#   default            — one private zone per name, seeded with the owner VPC; a Profile; one
#                        zone->Profile resource association per zone; RAM share + resource
#                        association + one principal association per consumer.
#   multi zone         — the zone / resource-association counts track the private_zones list.
#   no consumers       — the RAM share, resource association, and principal associations all
#                        drop to zero, and the consumers_declared check fails.
#   bad seed vpc       — a seed_vpc_id that is not a vpc- id fails at variable validation.
#   empty zones        — an empty private_zones list fails at variable validation.
#   bad consumer id    — a non-12-digit consumer account id fails at variable validation.

mock_provider "aws" {
  # aws_route53_zone.arn is consumed by the resource association; give it a well-formed value.
  mock_resource "aws_route53_zone" {
    defaults = {
      arn = "arn:aws:route53:::hostedzone/ZMOCKPRIVATE001"
    }
  }
  mock_resource "aws_route53profiles_profile" {
    defaults = {
      id  = "rp-mock0000000001"
      arn = "arn:aws:route53profiles:us-west-2:111111111111:profile/rp-mock0000000001"
    }
  }
  # aws_ram_resource_association / _principal_association validate the share ARN prefix at plan;
  # the mock's random string is not a valid ARN, so pin a well-formed one.
  mock_resource "aws_ram_resource_share" {
    defaults = {
      arn = "arn:aws:ram:us-west-2:111111111111:resource-share/mock-0000-0000-000000000000"
    }
  }
}

variables {
  environment = "development"
  region      = "us-west-2"
  team        = "platform"
  seed_vpc_id = "vpc-00aa11bb22cc33dd4"

  # Valid defaults so a run testing one specific failure (a bad seed vpc, empty zones) does not
  # also trip the consumers_declared check as an unrelated second failure. Runs override what
  # they exercise.
  private_zones        = ["internal.nanohype"]
  consumer_account_ids = ["222222222222"]
}

# ── default: zones seeded, profile built, zones attached, RAM shared to the consumer ──
run "default" {
  command = plan

  variables {
    private_zones        = ["internal.nanohype"]
    consumer_account_ids = ["222222222222"]
  }

  assert {
    condition     = length(aws_route53_zone.private) == 1
    error_message = "one private zone per private_zones entry"
  }
  assert {
    condition     = one(aws_route53_zone.private["internal.nanohype"].vpc).vpc_id == "vpc-00aa11bb22cc33dd4"
    error_message = "each private zone must be seeded with the owner-account VPC"
  }
  assert {
    condition     = aws_route53profiles_profile.this.name == "development-private-dns"
    error_message = "the Profile must be named <environment>-private-dns"
  }
  assert {
    condition     = length(aws_route53profiles_resource_association.zone) == 1
    error_message = "each zone must be attached to the Profile"
  }
  assert {
    condition     = length(aws_ram_resource_share.profile) == 1
    error_message = "the Profile must be RAM-shared when consumers are declared"
  }
  assert {
    condition     = length(aws_ram_resource_association.profile) == 1
    error_message = "the Profile ARN must be associated to the RAM share"
  }
  assert {
    condition     = length(aws_ram_principal_association.consumer) == 1
    error_message = "one principal association per consumer account"
  }
}

# ── multi-zone: counts track the list ──
run "multi_zone" {
  command = plan

  variables {
    private_zones        = ["internal.nanohype", "svc.nanohype", "data.nanohype"]
    consumer_account_ids = ["222222222222", "333333333333"]
  }

  assert {
    condition     = length(aws_route53_zone.private) == 3
    error_message = "zone count must track private_zones"
  }
  assert {
    condition     = length(aws_route53profiles_resource_association.zone) == 3
    error_message = "one Profile attachment per zone"
  }
  assert {
    condition     = length(aws_ram_principal_association.consumer) == 2
    error_message = "one principal association per consumer"
  }
}

# ── no consumers: the whole RAM share drops to zero and the soft check fires ──
run "no_consumers" {
  command = plan

  variables {
    private_zones        = ["internal.nanohype"]
    consumer_account_ids = []
  }

  assert {
    condition     = length(aws_ram_resource_share.profile) == 0
    error_message = "no RAM share without consumers"
  }
  assert {
    condition     = length(aws_ram_resource_association.profile) == 0
    error_message = "no RAM resource association without consumers"
  }
  assert {
    condition     = length(aws_ram_principal_association.consumer) == 0
    error_message = "no principal associations without consumers"
  }

  expect_failures = [
    check.consumers_declared,
  ]
}

# ── bad seed vpc id: rejected at variable validation ──
run "bad_seed_vpc" {
  command = plan

  variables {
    private_zones = ["internal.nanohype"]
    seed_vpc_id   = "not-a-vpc"
  }

  expect_failures = [
    var.seed_vpc_id,
  ]
}

# ── empty zones: rejected at variable validation ──
run "empty_zones" {
  command = plan

  variables {
    private_zones = []
  }

  expect_failures = [
    var.private_zones,
  ]
}

# ── bad consumer id: rejected at variable validation ──
run "bad_consumer_id" {
  command = plan

  variables {
    private_zones        = ["internal.nanohype"]
    consumer_account_ids = ["22222"]
  }

  expect_failures = [
    var.consumer_account_ids,
  ]
}
