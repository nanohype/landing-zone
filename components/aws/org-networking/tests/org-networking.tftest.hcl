# Unit tests for org-networking's central-egress static route. Runs against a mocked AWS
# provider (no AWS access). Covers the additive, owner-side default route that makes
# centralized egress functional:
#
#   egress_route_off — no attachment wired (default): no static 0.0.0.0/0 route is planned.
#   egress_route_on  — the egress hub's attachment wired: a static 0.0.0.0/0 route to it is
#                      planned in the TGW default route table.

mock_provider "aws" {
  # aws_ram_resource_association validates its ARNs at plan, so the TGW and share must carry
  # ARN-shaped values (the mock's default random value is not).
  mock_resource "aws_ec2_transit_gateway" {
    defaults = {
      arn = "arn:aws:ec2:us-west-2:111111111111:transit-gateway/tgw-mock"
    }
  }
  mock_resource "aws_ram_resource_share" {
    defaults = {
      arn = "arn:aws:ram:us-west-2:111111111111:resource-share/mock"
    }
  }
}

variables {
  environment = "org"
  region      = "us-west-2"
  team        = "platform"
}

# ── no egress attachment wired: the additive default route stays off ──
run "egress_route_off" {
  command = plan

  assert {
    condition     = length(aws_ec2_transit_gateway_route.egress_default) == 0
    error_message = "with no egress_tgw_attachment_id, no static 0.0.0.0/0 route should be planned"
  }
}

# ── egress hub attachment wired: a static 0.0.0.0/0 route targets it ──
run "egress_route_on" {
  command = plan

  variables {
    egress_tgw_attachment_id = "tgw-attach-0abc123def4567890"
  }

  assert {
    condition     = length(aws_ec2_transit_gateway_route.egress_default) == 1
    error_message = "wiring egress_tgw_attachment_id must plan the static central-egress route"
  }
  assert {
    condition     = aws_ec2_transit_gateway_route.egress_default[0].destination_cidr_block == "0.0.0.0/0"
    error_message = "the central-egress route must be the default route (0.0.0.0/0)"
  }
  assert {
    condition     = aws_ec2_transit_gateway_route.egress_default[0].transit_gateway_attachment_id == "tgw-attach-0abc123def4567890"
    error_message = "the central-egress route must target the wired egress-hub attachment"
  }
}
