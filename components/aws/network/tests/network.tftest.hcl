# Unit tests for the mode-aware network component. Runs against a mocked AWS provider (no
# AWS access), so they gate the create/adopt behavior contract:
#
#   create default    — a VPC is built, no IPAM preview/pin, no TGW attachment; subnet AZ
#                        IDs resolve to cross-account-stable zone IDs.
#   create + IPAM      — the VPC CIDR is drawn from the pool; the carving base is pinned.
#   create + TGW +     — zero NAT gateways and a default egress route to the transit
#     centralized        gateway are planned.
#   adopt (happy)      — nothing is built (no endpoint SG, no TGW, no preview); outputs
#                        resolve from the supplied IDs; the preflight passes.
#   adopt (bad vpc)    — a subnet outside adopt_vpc_id fails the plan at the preflight.
#   adopt (no S3 rt)   — a private route table without any S3 gateway route fails the plan.
#   adopt (wrong plist)— a route table with a non-S3 (e.g. DynamoDB) prefix-list route
#                        fails: the preflight matches the exact S3 prefix list, not any.
#   adopt (blackhole)  — a 0.0.0.0/0 route with no live target (deleted NAT) fails: the
#                        preflight asserts the egress target, not just the destination.
#   mode conflicts     — adopt + a create-mode lever, and create + adopt_* fields, are
#                        rejected at variable validation, not silently ignored.
#   ipam netmask range — a netmask below AWS's /28 subnet floor is rejected with the
#                        variable's own message, not a raw cidrsubnet provider error.
#   ipam pin day-2     — after apply, a later preview returning a new CIDR does not shift
#                        the pinned carving base (no destructive subnet replan).
#   nat in-between     — an explicit nat_gateways between 1 and max_azs is rejected at
#                        variable validation (the module can build only 1 or one-per-AZ).
#   nat per-az         — nat_gateways = max_azs plans exactly one NAT gateway per zone.

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
  mock_data "aws_vpc" {
    defaults = {
      cidr_block = "10.9.0.0/16"
    }
  }
  # The region's AWS-managed S3 gateway prefix list. The adopt preflight asserts this exact
  # ID is routed, so the happy-path route-table mock below routes pl-s3mock to match.
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = {
      id = "pl-s3mock"
    }
  }
  # Happy-path adopt defaults: every subnet is in adopt_vpc_id and every private route
  # table carries the S3 gateway prefix-list route plus a default egress route. The
  # failure runs override these per-instance to inject the contract violation.
  mock_data "aws_subnet" {
    defaults = {
      vpc_id               = "vpc-adopt"
      availability_zone    = "us-west-2a"
      availability_zone_id = "usw2-az1"
    }
  }
  # A route object carries the full aws_route_table.routes schema; the mock must supply
  # every field. The S3 gateway route sets destination_prefix_list_id + vpc_endpoint_id;
  # the default egress route sets cidr_block + nat_gateway_id. All other targets are "".
  mock_data "aws_route_table" {
    defaults = {
      route_table_id = "rtb-mock"
      routes = [
        {
          cidr_block                 = ""
          ipv6_cidr_block            = ""
          destination_prefix_list_id = "pl-s3mock"
          carrier_gateway_id         = ""
          core_network_arn           = ""
          egress_only_gateway_id     = ""
          gateway_id                 = ""
          instance_id                = ""
          local_gateway_id           = ""
          nat_gateway_id             = ""
          network_interface_id       = ""
          odb_network_arn            = ""
          transit_gateway_id         = ""
          vpc_endpoint_id            = "vpce-s3mock"
          vpc_peering_connection_id  = ""
        },
        {
          cidr_block                 = "0.0.0.0/0"
          ipv6_cidr_block            = ""
          destination_prefix_list_id = ""
          carrier_gateway_id         = ""
          core_network_arn           = ""
          egress_only_gateway_id     = ""
          gateway_id                 = ""
          instance_id                = ""
          local_gateway_id           = ""
          nat_gateway_id             = "nat-mock"
          network_interface_id       = ""
          odb_network_arn            = ""
          transit_gateway_id         = ""
          vpc_endpoint_id            = ""
          vpc_peering_connection_id  = ""
        },
      ]
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
  environment = "development"
  region      = "us-west-2"
  team        = "platform"
}

# ── create default: VPC built, no IPAM, no TGW ──
run "create_default" {
  command = plan

  assert {
    condition     = length(aws_security_group.vpc_endpoints) == 1
    error_message = "create mode must build the VPC-endpoints security group"
  }
  assert {
    condition     = length(data.aws_vpc_ipam_preview_next_cidr.this) == 0
    error_message = "no IPAM preview should run when ipam_pool_id is unset"
  }
  assert {
    condition     = length(aws_ec2_transit_gateway_vpc_attachment.this) == 0
    error_message = "no TGW attachment should be planned without transit_gateway_id"
  }
  assert {
    condition     = length(terraform_data.ipam_cidr_pin) == 0
    error_message = "no IPAM carving-base pin should exist when ipam_pool_id is unset"
  }
  assert {
    condition     = join(",", output.private_subnet_az_ids) == "usw2-az1,usw2-az2,usw2-az3"
    error_message = "create mode must resolve subnet AZ IDs (usw2-azN) from the AZ data source's zone_ids, in order"
  }
  assert {
    condition     = length(output.nat_gateway_ids) == 1
    error_message = "nat_gateways = 1 (default) must plan exactly one shared NAT gateway"
  }
  assert {
    condition     = length(module.vpc_flow_logs) == 0
    error_message = "flow logs are off by default (enable_flow_logs = false) — no flow-log module instance"
  }
}

# ── create + flow logs: the shared vpc-flow-logs module is instantiated and wired ──
run "create_flow_logs_enabled" {
  command = plan

  variables {
    enable_flow_logs = true
  }

  assert {
    condition     = length(module.vpc_flow_logs) == 1
    error_message = "enable_flow_logs = true (create mode) must instantiate the vpc-flow-logs module"
  }
  assert {
    condition     = module.vpc_flow_logs[0].log_group_name == "/aws/vpc-flow-logs/development"
    error_message = "the flow log must write to /aws/vpc-flow-logs/<environment>"
  }
  assert {
    condition     = module.vpc_flow_logs[0].iam_role_name == "development-vpc-flow-logs"
    error_message = "the flow-log IAM role must be named <environment>-vpc-flow-logs"
  }
  assert {
    condition     = module.vpc_flow_logs[0].traffic_type == "ALL"
    error_message = "the flow log must capture ALL traffic"
  }
}

# ── adopt + flow logs: create-mode flow logs stay off in adopt mode (the owner logs) ──
run "adopt_builds_no_flow_logs" {
  command = plan

  variables {
    network_mode             = "adopt"
    adopt_vpc_id             = "vpc-adopt"
    adopt_private_subnet_ids = ["subnet-a"]
    adopt_public_subnet_ids  = []
    max_azs                  = 1
    enable_flow_logs         = true
  }

  assert {
    condition     = length(module.vpc_flow_logs) == 0
    error_message = "adopt mode must not build flow logs even with enable_flow_logs = true — the network owner logs the shared VPC"
  }
}

# ── create + IPAM: CIDR drawn from the pool, carving base pinned ──
run "create_ipam" {
  command = plan

  variables {
    ipam_pool_id        = "ipam-pool-05mock"
    ipam_netmask_length = 16
  }

  assert {
    condition     = length(data.aws_vpc_ipam_preview_next_cidr.this) == 1
    error_message = "the VPC CIDR must be drawn from the IPAM pool via the preview data source"
  }
  assert {
    condition     = length(terraform_data.ipam_cidr_pin) == 1
    error_message = "create+IPAM must pin the previewed carving base in state (terraform_data.ipam_cidr_pin)"
  }
  assert {
    condition     = length(aws_security_group.vpc_endpoints) == 1
    error_message = "create+IPAM must still build the endpoint security group"
  }
}

# ── create + TGW + centralized egress: 0 NAT gateways, default route to TGW ──
run "create_tgw_centralized" {
  command = plan

  variables {
    ipam_pool_id        = "ipam-pool-05mock"
    ipam_netmask_length = 16
    transit_gateway_id  = "tgw-05mock"
    centralized_egress  = true
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

# ── nat_gateways: an in-between count (neither 1 nor max_azs) is rejected at plan, not
#    silently rounded up to per-AZ — the module cannot build an arbitrary NAT count ──
run "nat_gateways_rejects_in_between" {
  command = plan

  variables {
    # max_azs defaults to 3, so 2 is neither a single shared NAT nor one-per-AZ.
    nat_gateways = 2
  }

  expect_failures = [
    var.nat_gateways,
  ]
}

# ── nat_gateways = max_azs: one NAT gateway per zone (the honored per-AZ count) ──
run "nat_gateways_per_az" {
  command = plan

  variables {
    nat_gateways = 3
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 3
    error_message = "nat_gateways = max_azs must plan exactly one NAT gateway per zone (3)"
  }
}

# ── adopt happy path: nothing built, outputs resolve, preflight passes ──
run "adopt_happy" {
  command = plan

  variables {
    network_mode             = "adopt"
    adopt_vpc_id             = "vpc-adopt"
    adopt_private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    adopt_public_subnet_ids  = ["subnet-x", "subnet-y", "subnet-z"]
    max_azs                  = 1
  }

  assert {
    condition     = length(aws_security_group.vpc_endpoints) == 0
    error_message = "adopt mode must not build the endpoint security group (the owner runs endpoints)"
  }
  assert {
    condition     = length(aws_ec2_transit_gateway_vpc_attachment.this) == 0
    error_message = "adopt mode must not build a TGW attachment"
  }
  assert {
    condition     = length(data.aws_vpc_ipam_preview_next_cidr.this) == 0
    error_message = "adopt mode must not run the IPAM preview"
  }
  assert {
    condition     = output.vpc_id == "vpc-adopt"
    error_message = "adopt mode must resolve vpc_id from adopt_vpc_id"
  }
  assert {
    condition     = join(",", output.private_subnet_ids) == "subnet-a,subnet-b,subnet-c"
    error_message = "adopt mode must resolve private_subnet_ids from the supplied IDs, in order"
  }
  assert {
    condition     = output.private_subnet_az_ids[0] == "usw2-az1"
    error_message = "adopt mode must expose cross-account-stable AZ IDs (usw2-azN) from the subnet data sources, not AZ names"
  }
  assert {
    condition     = output.network_mode == "adopt"
    error_message = "network_mode must be published so consumers can derive subnet-tagging ownership"
  }
}

# ── adopt failure: a subnet outside adopt_vpc_id fails the preflight at plan ──
run "adopt_subnet_wrong_vpc" {
  command = plan

  variables {
    network_mode             = "adopt"
    adopt_vpc_id             = "vpc-adopt"
    adopt_private_subnet_ids = ["subnet-a"]
    adopt_public_subnet_ids  = []
    max_azs                  = 1
  }

  override_data {
    target = data.aws_subnet.adopt_private
    values = {
      vpc_id            = "vpc-someone-else"
      availability_zone = "us-west-2a"
    }
  }

  expect_failures = [
    data.aws_subnet.adopt_private,
  ]
}

# ── adopt failure: a private route table missing the S3 gateway route fails at plan ──
run "adopt_missing_s3_route" {
  command = plan

  variables {
    network_mode             = "adopt"
    adopt_vpc_id             = "vpc-adopt"
    adopt_private_subnet_ids = ["subnet-a"]
    adopt_public_subnet_ids  = []
    max_azs                  = 1
  }

  # A route table with a default egress route but NO S3 gateway prefix-list route —
  # the exact contract violation the preflight must catch.
  override_data {
    target = data.aws_route_table.adopt_private
    values = {
      route_table_id = "rtb-nobody"
      routes = [
        {
          cidr_block                 = "0.0.0.0/0"
          ipv6_cidr_block            = ""
          destination_prefix_list_id = ""
          carrier_gateway_id         = ""
          core_network_arn           = ""
          egress_only_gateway_id     = ""
          gateway_id                 = ""
          instance_id                = ""
          local_gateway_id           = ""
          nat_gateway_id             = "nat-mock"
          network_interface_id       = ""
          odb_network_arn            = ""
          transit_gateway_id         = ""
          vpc_endpoint_id            = ""
          vpc_peering_connection_id  = ""
        },
      ]
    }
  }

  expect_failures = [
    data.aws_route_table.adopt_private,
  ]
}

# ── adopt failure: a prefix-list route for a NON-S3 service passes a loose check but must
#    fail the exact-S3 assertion (the wrong-prefix-list probe) ──
run "adopt_wrong_s3_prefix" {
  command = plan

  variables {
    network_mode             = "adopt"
    adopt_vpc_id             = "vpc-adopt"
    adopt_private_subnet_ids = ["subnet-a"]
    adopt_public_subnet_ids  = []
    max_azs                  = 1
  }

  # A route table whose only prefix-list route targets a DynamoDB (not S3) gateway, plus a
  # live default egress route. A "any non-empty prefix_list_id" check would wrongly pass;
  # the exact-S3 assertion must reject it.
  override_data {
    target = data.aws_route_table.adopt_private
    values = {
      route_table_id = "rtb-ddbonly"
      routes = [
        {
          cidr_block                 = ""
          ipv6_cidr_block            = ""
          destination_prefix_list_id = "pl-dynamodb"
          carrier_gateway_id         = ""
          core_network_arn           = ""
          egress_only_gateway_id     = ""
          gateway_id                 = ""
          instance_id                = ""
          local_gateway_id           = ""
          nat_gateway_id             = ""
          network_interface_id       = ""
          odb_network_arn            = ""
          transit_gateway_id         = ""
          vpc_endpoint_id            = "vpce-ddbmock"
          vpc_peering_connection_id  = ""
        },
        {
          cidr_block                 = "0.0.0.0/0"
          ipv6_cidr_block            = ""
          destination_prefix_list_id = ""
          carrier_gateway_id         = ""
          core_network_arn           = ""
          egress_only_gateway_id     = ""
          gateway_id                 = ""
          instance_id                = ""
          local_gateway_id           = ""
          nat_gateway_id             = "nat-mock"
          network_interface_id       = ""
          odb_network_arn            = ""
          transit_gateway_id         = ""
          vpc_endpoint_id            = ""
          vpc_peering_connection_id  = ""
        },
      ]
    }
  }

  expect_failures = [
    data.aws_route_table.adopt_private,
  ]
}

# ── adopt failure: a 0.0.0.0/0 route with no live target (blackholed by a deleted NAT)
#    passes a destination-only check but must fail the egress-target assertion ──
run "adopt_blackholed_default" {
  command = plan

  variables {
    network_mode             = "adopt"
    adopt_vpc_id             = "vpc-adopt"
    adopt_private_subnet_ids = ["subnet-a"]
    adopt_public_subnet_ids  = []
    max_azs                  = 1
  }

  # A valid S3 gateway route, but the default route's target is empty — a blackhole. A
  # "cidr_block == 0.0.0.0/0" check would wrongly pass; asserting the target must reject it.
  override_data {
    target = data.aws_route_table.adopt_private
    values = {
      route_table_id = "rtb-blackhole"
      routes = [
        {
          cidr_block                 = ""
          ipv6_cidr_block            = ""
          destination_prefix_list_id = "pl-s3mock"
          carrier_gateway_id         = ""
          core_network_arn           = ""
          egress_only_gateway_id     = ""
          gateway_id                 = ""
          instance_id                = ""
          local_gateway_id           = ""
          nat_gateway_id             = ""
          network_interface_id       = ""
          odb_network_arn            = ""
          transit_gateway_id         = ""
          vpc_endpoint_id            = "vpce-s3mock"
          vpc_peering_connection_id  = ""
        },
        {
          cidr_block                 = "0.0.0.0/0"
          ipv6_cidr_block            = ""
          destination_prefix_list_id = ""
          carrier_gateway_id         = ""
          core_network_arn           = ""
          egress_only_gateway_id     = ""
          gateway_id                 = ""
          instance_id                = ""
          local_gateway_id           = ""
          nat_gateway_id             = ""
          network_interface_id       = ""
          odb_network_arn            = ""
          transit_gateway_id         = ""
          vpc_endpoint_id            = ""
          vpc_peering_connection_id  = ""
        },
      ]
    }
  }

  expect_failures = [
    data.aws_route_table.adopt_private,
  ]
}

# ── mode conflict: adopt mode with a create-mode lever set is rejected, not ignored ──
run "adopt_rejects_create_lever" {
  command = plan

  variables {
    network_mode             = "adopt"
    adopt_vpc_id             = "vpc-adopt"
    adopt_private_subnet_ids = ["subnet-a"]
    adopt_public_subnet_ids  = []
    max_azs                  = 1
    # A create-mode lever alongside adopt mode. ipam_netmask_length is set to a valid value
    # so only ipam_pool_id's adopt-reject validation fails, nothing coupled to it.
    ipam_pool_id        = "ipam-pool-05mock"
    ipam_netmask_length = 16
  }

  expect_failures = [
    var.ipam_pool_id,
  ]
}

# ── mode conflict: create mode with adopt_* fields set is rejected, not ignored ──
run "create_rejects_adopt_fields" {
  command = plan

  variables {
    network_mode = "create"
    adopt_vpc_id = "vpc-adopt"
  }

  expect_failures = [
    var.adopt_vpc_id,
  ]
}

# ── ipam netmask range: a base longer than /20 carves sub-/28 subnets AWS rejects, so the
#    variable validation must catch it before the raw cidrsubnet provider error ──
run "ipam_netmask_too_long" {
  command = plan

  variables {
    ipam_pool_id        = "ipam-pool-05mock"
    ipam_netmask_length = 26
  }

  expect_failures = [
    var.ipam_netmask_length,
  ]
}

# ── ipam pin: after apply, a later preview returning a different CIDR must not shift the
#    pinned carving base — the guard against the day-2 destructive subnet replan ──
run "ipam_pin_apply" {
  command = apply

  variables {
    ipam_pool_id        = "ipam-pool-05mock"
    ipam_netmask_length = 16
  }

  assert {
    condition     = terraform_data.ipam_cidr_pin[0].output == "10.42.0.0/16"
    error_message = "the IPAM carving base must pin to the first previewed CIDR after apply"
  }
}

run "ipam_pin_holds_on_day2" {
  command = plan

  variables {
    ipam_pool_id        = "ipam-pool-05mock"
    ipam_netmask_length = 16
  }

  # Simulate the pool having allocated the first block: the preview now returns the next
  # free CIDR. The pinned base must ignore it, or every subnet would replan destructively.
  override_data {
    target = data.aws_vpc_ipam_preview_next_cidr.this
    values = {
      cidr = "10.99.0.0/16"
    }
  }

  assert {
    condition     = data.aws_vpc_ipam_preview_next_cidr.this[0].cidr == "10.99.0.0/16" && terraform_data.ipam_cidr_pin[0].output == "10.42.0.0/16"
    error_message = "the preview may move on day 2, but the pinned carving base must stay at the first applied CIDR (proves the pin is load-bearing, not decorative)"
  }
}
