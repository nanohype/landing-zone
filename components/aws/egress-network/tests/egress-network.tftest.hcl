# Unit tests for the egress hub component. Runs against a mocked AWS provider (no AWS
# access), so it gates the hub's owner-side behavior + contract:
#
#   default_hub         — VPC + one shared NAT + a cross-account TGW attachment (appliance
#                         mode on) + a spoke return route on the public route table.
#   nat_per_az          — nat_gateways = max_azs plans one NAT gateway per zone.
#   nat_rejects_between  — an explicit nat_gateways between 1 and max_azs is rejected.
#   cidr_overlaps_supernet — an egress CIDR inside the workload supernet fails the contract
#                            check (would collide with a spoke and break TGW routing).
#   supernet_nested_in_egress — the reverse nesting (supernet inside a wider egress CIDR)
#                            also fails the contract check (bidirectional overlap).
#   invalid_supernet_cidr — a malformed spoke_supernet_cidr is rejected by variable
#                            validation with a clear message, before the overlap check runs.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]
      zone_ids = ["usw2-az1", "usw2-az2", "usw2-az3", "usw2-az4"]
    }
  }
  # aws_flow_log ARN-validates iam_role_arn + log_destination at plan, and the
  # mock's random default is not ARN-shaped — pin real ARNs for the flow-log role
  # and log group so the enable_flow_logs run plans.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/flow-logs-mock"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-west-2:123456789012:log-group:flow-logs-mock"
    }
  }
}

variables {
  environment        = "hub"
  region             = "us-west-2"
  team               = "platform"
  transit_gateway_id = "tgw-0abc123def4567890"
}

# ── default hub: VPC, single NAT, cross-account TGW attachment, spoke return route ──
run "default_hub" {
  command = plan

  assert {
    condition     = length(output.public_subnet_ids) == 3 && length(output.private_subnet_ids) == 3
    error_message = "the hub must build public + NAT-facing private subnets, one per AZ (3)"
  }
  assert {
    condition     = length(output.nat_gateway_ids) == 1
    error_message = "nat_gateways = 1 (default) must plan exactly one shared NAT gateway"
  }
  assert {
    condition     = aws_ec2_transit_gateway_vpc_attachment.this.appliance_mode_support == "enable"
    error_message = "appliance mode must be enabled so stateful NAT flows stay pinned to one AZ"
  }
  assert {
    condition     = length(aws_route.spoke_return) >= 1
    error_message = "the public route table must carry a return route to the spokes through the TGW"
  }
  assert {
    condition     = aws_route.spoke_return[0].destination_cidr_block == "10.0.0.0/8"
    error_message = "the spoke return route must target the workload supernet (default 10.0.0.0/8)"
  }
}

# ── flow logs: the egress hub logs egress traffic for visibility ──
run "flow_logs_enabled" {
  command = plan

  variables {
    enable_flow_logs = true
  }

  assert {
    condition     = length(module.vpc_flow_logs) == 1
    error_message = "enable_flow_logs = true must instantiate the egress vpc-flow-logs module"
  }
  assert {
    condition     = module.vpc_flow_logs[0].log_group_name == "/aws/vpc-flow-logs/hub-egress"
    error_message = "the egress hub's flow log must write to /aws/vpc-flow-logs/<environment>-egress"
  }
  assert {
    condition     = module.vpc_flow_logs[0].iam_role_name == "hub-egress-flow-logs"
    error_message = "the flow-log IAM role must be named <environment>-egress-flow-logs"
  }
}

# ── flow logs off by default: no flow-log module instance ──
run "flow_logs_off_by_default" {
  command = plan

  assert {
    condition     = length(module.vpc_flow_logs) == 0
    error_message = "flow logs are off by default (enable_flow_logs = false) — no flow-log module instance"
  }
}

# ── per-AZ NAT: nat_gateways = max_azs plans one NAT gateway per zone ──
run "nat_per_az" {
  command = plan

  variables {
    nat_gateways = 3
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 3
    error_message = "nat_gateways = max_azs must plan exactly one NAT gateway per zone (3)"
  }
}

# ── nat_gateways: an in-between count (neither 1 nor max_azs) is rejected at plan ──
run "nat_rejects_between" {
  command = plan

  variables {
    # max_azs defaults to 3, so 2 is neither a single shared NAT nor one-per-AZ.
    nat_gateways = 2
  }

  expect_failures = [
    var.nat_gateways,
  ]
}

# ── contract: an egress CIDR inside the workload supernet must fail the overlap check ──
run "cidr_overlaps_supernet" {
  command = plan

  variables {
    # 10.5.0.0/16 sits inside the default spoke_supernet_cidr (10.0.0.0/8).
    egress_vpc_cidr = "10.5.0.0/16"
  }

  expect_failures = [
    check.egress_cidr_outside_spoke_supernet,
  ]
}

# ── contract: the reverse nesting (supernet inside a wider egress CIDR) must also fail ──
# The original one-directional check only caught egress-inside-supernet; this fixture pins
# the bidirectional behavior. Here the /24 supernet sits inside the /16 egress block, which
# the egress-inside-supernet test alone would have missed.
run "supernet_nested_in_egress" {
  command = plan

  variables {
    egress_vpc_cidr     = "100.64.0.0/16"
    spoke_supernet_cidr = "100.64.5.0/24"
  }

  expect_failures = [
    check.egress_cidr_outside_spoke_supernet,
  ]
}

# ── validation: a malformed spoke_supernet_cidr is rejected before the overlap check runs ──
run "invalid_supernet_cidr" {
  command = plan

  variables {
    spoke_supernet_cidr = "not-a-cidr"
  }

  expect_failures = [
    var.spoke_supernet_cidr,
  ]
}
