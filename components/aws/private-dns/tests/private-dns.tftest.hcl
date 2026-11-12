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
#   zone tag limit     — every private zone carries at most 10 tags (Route 53's
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
  # Happy-path VPC: DNS resolution enabled. The dns-off runs override this.
  mock_data "aws_vpc" {
    defaults = {
      enable_dns_support = true
    }
  }
}

# Hosted zones are created through the default_tags-free provider in route53-tags.tf.
mock_provider "aws" {
  alias = "route53"

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
  region      = "us-east-1"
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

# ── zone tag limit: the root default_tags plus the component's tags fit in one Route 53 call ──
#
# ChangeTagsForResource takes at most 10 tags, and the provider sends a zone's whole set in
# one call. Before route53-tags.tf each zone carried the 11 default tags plus Component,
# Team and Name: 14, refused by Route 53 on create.
run "zone_tags_within_route53_limit" {
  command = plan

  variables {
    dns_mode      = "create"
    private_zones = ["internal.development.example.com"]
  }

  assert {
    condition     = alltrue([for z in values(aws_route53_zone.private) : length(z.tags) <= 10])
    error_message = "every private hosted zone must carry at most 10 tags, the most one Route 53 ChangeTagsForResource call accepts"
  }
  assert {
    condition = alltrue([
      for k in ["Environment", "ManagedBy", "CostCenter", "BusinessUnit", "DataClassification", "Team"] :
      contains(keys(aws_route53_zone.private["internal.development.example.com"].tags), k)
    ])
    error_message = "the hosted zone must keep every key the org-compliance required-tags rule checks"
  }
}

# ── one tag over the limit fails the plan, not the CreateHostedZone that follows it ──
run "zone_tags_over_route53_limit_fail_the_plan" {
  command = plan

  variables {
    dns_mode      = "create"
    private_zones = ["internal.development.example.com"]
    tags          = { CostAllocation = "shared" }
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

  variables {
    dns_mode      = "create"
    private_zones = ["internal.development.example.com"]
  }

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
