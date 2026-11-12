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
#   zone tag limit     — every zone carries at most 10 tags (Route 53's ChangeTagsForResource
#                        limit) under the real root default_tags, and one tag more fails the
#                        plan at the zone's precondition.

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
  mock_resource "aws_route53profiles_profile" {
    defaults = {
      id  = "rp-mock0000000001"
      arn = "arn:aws:route53profiles:us-east-1:111111111111:profile/rp-mock0000000001"
    }
  }
  # aws_ram_resource_association / _principal_association validate the share ARN prefix at plan;
  # the mock's random string is not a valid ARN, so pin a well-formed one.
  mock_resource "aws_ram_resource_share" {
    defaults = {
      arn = "arn:aws:ram:us-east-1:111111111111:resource-share/mock-0000-0000-000000000000"
    }
  }
}

# Hosted zones are created through the default_tags-free provider in route53-tags.tf.
mock_provider "aws" {
  alias = "route53"

  # aws_route53_zone.arn is consumed by the resource association; give it a well-formed value.
  mock_resource "aws_route53_zone" {
    defaults = {
      arn = "arn:aws:route53:::hostedzone/ZMOCKPRIVATE001"
    }
  }
}

variables {
  environment = "development"
  region      = "us-east-1"
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

# ── zone tag limit: the root default_tags plus the component's tags fit in one Route 53 call ──
#
# ChangeTagsForResource takes at most 10 tags, and the provider sends a zone's whole set in
# one call. Before route53-tags.tf each zone carried the 11 default tags plus Component,
# Team and Name: 14, refused by Route 53 on create.
run "zone_tags_within_route53_limit" {
  command = plan

  assert {
    condition     = alltrue([for z in values(aws_route53_zone.private) : length(z.tags) <= 10])
    error_message = "every shared private hosted zone must carry at most 10 tags, the most one Route 53 ChangeTagsForResource call accepts"
  }
  assert {
    condition = alltrue([
      for k in ["Environment", "ManagedBy", "CostCenter", "BusinessUnit", "DataClassification", "Team"] :
      contains(keys(aws_route53_zone.private["internal.nanohype"].tags), k)
    ])
    error_message = "the hosted zone must keep every key the org-compliance required-tags rule checks"
  }
}

# ── one tag over the limit fails the plan, not the CreateHostedZone that follows it ──
run "zone_tags_over_route53_limit_fail_the_plan" {
  command = plan

  variables {
    tags = { CostAllocation = "shared" }
  }

  expect_failures = [
    aws_route53_zone.private,
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
    target = aws_route53_zone.private
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
    aws_route53_zone.private,
  ]
}
