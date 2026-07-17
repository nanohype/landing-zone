# Unit tests for the mode-aware network component. Runs at command = plan against a
# mocked AWS provider (no AWS access), so they gate the create/adopt behavior contract:
#
#   create default   — a VPC is built, no IPAM preview, no TGW attachment.
#   create + IPAM     — the VPC CIDR is drawn from the pool (the preview data source runs).
#   create + TGW +    — zero NAT gateways and a default egress route to the transit
#     centralized       gateway are planned.
#   adopt (happy)     — nothing is built (no endpoint SG, no TGW, no preview); outputs
#                       resolve from the supplied IDs; the preflight passes.
#   adopt (bad vpc)   — a subnet outside adopt_vpc_id fails the plan at the preflight.
#   adopt (no S3 rt)  — a private route table without the S3 gateway route fails the plan.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]
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
  # Happy-path adopt defaults: every subnet is in adopt_vpc_id and every private route
  # table carries the S3 gateway prefix-list route plus a default egress route. The
  # failure runs override these per-instance to inject the contract violation.
  mock_data "aws_subnet" {
    defaults = {
      vpc_id            = "vpc-adopt"
      availability_zone = "us-west-2a"
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
}

# ── create + IPAM: CIDR drawn from the pool ──
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
