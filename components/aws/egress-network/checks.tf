# Owner-side contract assertion for the egress hub.
#
# check blocks surface a breach as a plan/apply warning (non-blocking by design), and the
# tofu test suite gates them hard via expect_failures — so a regression that puts the egress
# VPC inside the workload supernet fails CI, not just the next apply's log.

locals {
  # Two CIDRs overlap when the more-specific one's network address, masked to the wider
  # prefix, equals the wider one's network address. egress_vpc_cidr is always /16../24 and
  # spoke_supernet_cidr is the /8-class org supernet, so egress is the more-specific side:
  # project its base into the supernet's prefix and compare. Equal => egress sits inside the
  # supernet (overlap); different => disjoint.
  egress_base_in_supernet = cidrhost(
    "${cidrhost(var.egress_vpc_cidr, 0)}/${split("/", var.spoke_supernet_cidr)[1]}", 0
  ) == cidrhost(var.spoke_supernet_cidr, 0)
}

check "egress_cidr_outside_spoke_supernet" {
  assert {
    condition     = !local.egress_base_in_supernet
    error_message = "egress_vpc_cidr (${var.egress_vpc_cidr}) overlaps spoke_supernet_cidr (${var.spoke_supernet_cidr}). The egress hub is dedicated infrastructure space and must sit OUTSIDE the workload supernet — an overlap would collide with a spoke drawn from the org IPAM pools and break transit gateway routing. Use carrier-grade NAT space (100.64.0.0/10) or another block outside the supernet."
  }
}
