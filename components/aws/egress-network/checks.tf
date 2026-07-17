# Owner-side contract assertion for the egress hub.
#
# check blocks surface a breach as a plan/apply warning (non-blocking by design), and the
# tofu test suite gates them hard via expect_failures — so a regression that puts the egress
# VPC inside the workload supernet fails CI, not just the next apply's log.

locals {
  egress_prefix   = split("/", var.egress_vpc_cidr)[1]
  supernet_prefix = split("/", var.spoke_supernet_cidr)[1]
  egress_base     = cidrhost(var.egress_vpc_cidr, 0)
  supernet_base   = cidrhost(var.spoke_supernet_cidr, 0)

  # Two CIDRs overlap when either one's network address falls inside the other block. The
  # committed defaults have egress as the more-specific side (a /16../24 dedicated block vs.
  # the /8-class org supernet), but the check is bidirectional so it also catches the reverse
  # nesting — a narrow supernet sitting inside a wider egress CIDR:
  #
  #   egress-inside-supernet: mask the egress base to the supernet's prefix; equal to the
  #                           supernet base => egress sits inside the supernet.
  #   supernet-inside-egress: mask the supernet base to the egress prefix; equal to the egress
  #                           base => the supernet sits inside the egress block.
  #
  # Either direction is an overlap. Disjoint blocks fail both tests.
  egress_base_in_supernet = cidrhost("${local.egress_base}/${local.supernet_prefix}", 0) == local.supernet_base
  supernet_base_in_egress = cidrhost("${local.supernet_base}/${local.egress_prefix}", 0) == local.egress_base
  cidrs_overlap           = local.egress_base_in_supernet || local.supernet_base_in_egress
}

check "egress_cidr_outside_spoke_supernet" {
  assert {
    condition     = !local.cidrs_overlap
    error_message = "egress_vpc_cidr (${var.egress_vpc_cidr}) overlaps spoke_supernet_cidr (${var.spoke_supernet_cidr}). The egress hub is dedicated infrastructure space and must sit OUTSIDE the workload supernet — an overlap would collide with a spoke drawn from the org IPAM pools and break transit gateway routing. Use carrier-grade NAT space (100.64.0.0/10) or another block outside the supernet."
  }
}
