# Unit tests for the shared-network owner component. Runs against a mocked AWS provider (no
# AWS access), so they gate the owner-side behavior + contract:
#
#   nat_egress          — local-NAT owner VPC: endpoints built, ELB role tags present with
#                         NO cluster-ownership tag, subnets RAM-shared to every consumer.
#   tgw_centralized     — centralized-egress owner VPC: zero NAT gateways, a TGW attachment,
#                         and a 0.0.0.0/0 route to the transit gateway.
#   contract_no_endpoints — dropping the endpoint set fails the owner contract check.
#   contract_no_consumers — an empty consumer list fails the owner contract check.
#   ipam_pin_apply /    — the previewed carving base pins in state and does not shift when a
#     ipam_pin_holds_day2  later preview returns a different CIDR (no destructive replan).
#   ipam_netmask_range  — a base longer than /20 is rejected by the variable's own message.
#   discovery_resolves  — with no explicit pool, the env sub-pool is discovered by tag.
#   discovery_zero_match — no pool carries the org-ipam tag: a clear postcondition error, not
#                          a raw null-attribute crash.
#   contract_cluster_tag — a kubernetes.io/cluster/* tag injected via var.tags lands on every
#                          shared subnet and fails the role-tag contract check.
#   nat in-between /     — an explicit nat_gateways between 1 and max_azs is rejected; a value
#     nat per-az           equal to max_azs plans one NAT gateway per zone.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]
      zone_ids = ["usw2-az1", "usw2-az2", "usw2-az3", "usw2-az4"]
    }
  }
  mock_data "aws_vpc_ipam_preview_next_cidr" {
    defaults = {
      cidr = "10.42.0.0/16"
    }
  }
  mock_data "aws_vpc_ipam_pools" {
    defaults = {
      ipam_pools = [{
        id                                = "ipam-pool-discovered"
        arn                               = "arn:aws:ec2::444444444444:ipam-pool/ipam-pool-discovered"
        address_family                    = "ipv4"
        allocation_default_netmask_length = 0
        allocation_max_netmask_length     = 0
        allocation_min_netmask_length     = 0
        allocation_resource_tags          = {}
        auto_import                       = false
        aws_service                       = ""
        description                       = "org-ipam-development"
        ipam_scope_id                     = "ipam-scope-mock"
        ipam_scope_type                   = "private"
        locale                            = "us-west-2"
        pool_depth                        = 2
        publicly_advertisable             = false
        source_ipam_pool_id               = "ipam-pool-toplevel"
        state                             = "create-complete"
        tags                              = { Name = "org-ipam-development" }
      }]
    }
  }
  # The RAM subnet + principal associations validate resource_share_arn as an ARN at plan,
  # so the share's computed arn must be ARN-shaped — the mock's default random value is not.
  mock_resource "aws_ram_resource_share" {
    defaults = {
      arn = "arn:aws:ram:us-west-2:444444444444:resource-share/mock"
    }
  }
  # The RAM subnet associations validate resource_arn as an ARN, so the subnets the VPC
  # module creates must carry ARN-shaped values (the mock's default random value is not).
  mock_resource "aws_subnet" {
    defaults = {
      arn = "arn:aws:ec2:us-west-2:444444444444:subnet/subnet-mock"
    }
  }
  # aws_flow_log ARN-validates iam_role_arn + log_destination at plan, and the
  # mock's random default is not ARN-shaped — pin real ARNs for the flow-log role
  # and log group so the enable_flow_logs run plans.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::444444444444:role/flow-logs-mock"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-west-2:444444444444:log-group:flow-logs-mock"
    }
  }
}

variables {
  environment  = "development"
  region       = "us-west-2"
  team         = "platform"
  ipam_pool_id = "ipam-pool-05mock"
}

# ── local-NAT owner VPC: endpoints, role tags (no cluster tag), RAM share ──
run "nat_egress" {
  command = plan

  variables {
    nat_gateways         = 1
    share_public_subnets = true
    consumer_account_ids = ["111111111111", "222222222222"]
  }

  assert {
    condition     = length(aws_security_group.vpc_endpoints) == 1
    error_message = "the owner must build the shared-VPC endpoint security group"
  }
  assert {
    condition     = length(aws_ec2_transit_gateway_vpc_attachment.this) == 0
    error_message = "no TGW attachment should be planned without transit_gateway_id"
  }
  assert {
    condition     = length(output.nat_gateway_ids) == 1
    error_message = "nat_gateways = 1 must plan exactly one shared NAT gateway"
  }
  assert {
    condition     = length(aws_ram_resource_share.subnets) == 1
    error_message = "a RAM resource share must be planned when consumers are declared"
  }
  assert {
    condition     = length(aws_ram_principal_association.consumer) == 2
    error_message = "one RAM principal association per consumer account"
  }
  assert {
    condition     = length(aws_ram_resource_association.subnet) == 6
    error_message = "3 private + 3 public subnets shared (share_public_subnets = true, 3 AZs) = 6 resource associations"
  }
  assert {
    condition     = contains(keys(output.subnet_role_tags.public), "kubernetes.io/role/elb") && contains(keys(output.subnet_role_tags.private), "kubernetes.io/role/internal-elb")
    error_message = "shared subnets must carry the ELB role tags"
  }
  assert {
    condition     = alltrue([for k in concat(keys(output.subnet_role_tags.public), keys(output.subnet_role_tags.private)) : !startswith(k, "kubernetes.io/cluster/")])
    error_message = "shared subnets must carry NO kubernetes.io/cluster/<cluster> ownership tag"
  }
}

# ── flow logs: the owner logs the shared VPC on behalf of every adopting account ──
run "flow_logs_enabled" {
  command = plan

  variables {
    enable_flow_logs     = true
    consumer_account_ids = ["111111111111"]
  }

  assert {
    condition     = length(module.vpc_flow_logs) == 1
    error_message = "enable_flow_logs = true must instantiate the shared vpc-flow-logs module"
  }
  assert {
    condition     = module.vpc_flow_logs[0].log_group_name == "/aws/vpc-flow-logs/development-shared"
    error_message = "the shared VPC's flow log must write to /aws/vpc-flow-logs/<environment>-shared"
  }
  assert {
    condition     = module.vpc_flow_logs[0].iam_role_name == "development-shared-net-flow-logs"
    error_message = "the flow-log IAM role must be named <environment>-shared-net-flow-logs"
  }
}

# ── flow logs off by default: no flow-log module instance ──
run "flow_logs_off_by_default" {
  command = plan

  variables {
    consumer_account_ids = ["111111111111"]
  }

  assert {
    condition     = length(module.vpc_flow_logs) == 0
    error_message = "flow logs are off by default (enable_flow_logs = false) — no flow-log module instance"
  }
}

# ── centralized egress: 0 NAT gateways, TGW attachment + default route to the TGW ──
run "tgw_centralized" {
  command = plan

  variables {
    transit_gateway_id   = "tgw-05mock"
    centralized_egress   = true
    consumer_account_ids = ["111111111111"]
  }

  assert {
    condition     = length(aws_ec2_transit_gateway_vpc_attachment.this) == 1
    error_message = "a TGW attachment must be planned when transit_gateway_id is set"
  }
  assert {
    condition     = length(aws_route.tgw_default_egress) >= 1
    error_message = "centralized egress must add a 0.0.0.0/0 route to the transit gateway"
  }
  assert {
    condition     = length(output.nat_gateway_ids) == 0
    error_message = "centralized egress must plan zero NAT gateways"
  }
}

# ── contract violation: dropping the endpoint set fails the owner check ──
run "contract_no_endpoints" {
  command = plan

  variables {
    enable_vpc_endpoints = false
    consumer_account_ids = ["111111111111"]
  }

  expect_failures = [
    check.endpoint_set_complete,
  ]
}

# ── contract violation: no declared consumers fails the owner check ──
run "contract_no_consumers" {
  command = plan

  variables {
    consumer_account_ids = []
  }

  expect_failures = [
    check.consumers_declared,
  ]
}

# ── IPAM pin: after apply, the carving base pins to the first previewed CIDR ──
run "ipam_pin_apply" {
  command = apply

  variables {
    consumer_account_ids = ["111111111111"]
  }

  assert {
    condition     = terraform_data.ipam_cidr_pin.output == "10.42.0.0/16"
    error_message = "the IPAM carving base must pin to the first previewed CIDR after apply"
  }
}

# ── IPAM pin holds on day 2: a later preview returning a new CIDR must not shift the base ──
run "ipam_pin_holds_day2" {
  command = plan

  variables {
    consumer_account_ids = ["111111111111"]
  }

  override_data {
    target = data.aws_vpc_ipam_preview_next_cidr.this
    values = {
      cidr = "10.99.0.0/16"
    }
  }

  assert {
    condition     = data.aws_vpc_ipam_preview_next_cidr.this.cidr == "10.99.0.0/16" && terraform_data.ipam_cidr_pin.output == "10.42.0.0/16"
    error_message = "the preview may move on day 2, but the pinned carving base must stay at the first applied CIDR (proves the pin is load-bearing, not decorative)"
  }
}

# ── ipam netmask range: a base longer than /20 carves sub-/28 subnets AWS rejects ──
run "ipam_netmask_too_long" {
  command = plan

  variables {
    ipam_netmask_length  = 26
    consumer_account_ids = ["111111111111"]
  }

  expect_failures = [
    var.ipam_netmask_length,
  ]
}

# ── discovery: with no explicit pool, the org env sub-pool is discovered by its tag ──
run "discovery_resolves" {
  command = plan

  variables {
    ipam_pool_id         = ""
    consumer_account_ids = ["111111111111"]
  }

  assert {
    condition     = length(data.aws_vpc_ipam_pools.env) == 1
    error_message = "with no explicit ipam_pool_id, the env sub-pool must be discovered via data.aws_vpc_ipam_pools"
  }
  assert {
    condition     = output.ipam_pool_id == "ipam-pool-discovered"
    error_message = "the discovered pool ID must resolve from the tag lookup"
  }
}

# ── discovery zero-match: no pool carries the org-ipam tag → the data source's postcondition
#    fails with a clear message, not a raw null-attribute crash from one().id ──
run "discovery_zero_match" {
  command = plan

  variables {
    ipam_pool_id         = ""
    consumer_account_ids = ["111111111111"]
  }

  # Simulate the org-ipam-<env> tag matching no pool in this account (not shared yet, or the
  # tag is not visible cross-account over RAM).
  override_data {
    target = data.aws_vpc_ipam_pools.env
    values = {
      ipam_pools = []
    }
  }

  expect_failures = [
    data.aws_vpc_ipam_pools.env,
  ]
}

# ── contract violation: a kubernetes.io/cluster/* tag injected via var.tags lands on every
#    shared subnet and must fail the role-tag check (the effective-tag-set assertion) ──
run "contract_cluster_tag_via_tags" {
  command = plan

  variables {
    consumer_account_ids = ["111111111111"]
    tags = {
      "kubernetes.io/cluster/rogue" = "owned"
    }
  }

  expect_failures = [
    check.role_tags_no_cluster_binding,
  ]
}

# ── nat_gateways: an in-between count (neither 1 nor max_azs) is rejected at plan, not
#    silently rounded up to per-AZ ──
run "nat_gateways_rejects_in_between" {
  command = plan

  variables {
    # max_azs defaults to 3, so 2 is neither a single shared NAT nor one-per-AZ.
    nat_gateways         = 2
    consumer_account_ids = ["111111111111"]
  }

  expect_failures = [
    var.nat_gateways,
  ]
}

# ── nat_gateways = max_azs: one NAT gateway per zone (the honored per-AZ count) ──
run "nat_gateways_per_az" {
  command = plan

  variables {
    nat_gateways         = 3
    consumer_account_ids = ["111111111111"]
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 3
    error_message = "nat_gateways = max_azs must plan exactly one NAT gateway per zone (3)"
  }
}
