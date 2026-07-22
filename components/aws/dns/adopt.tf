# Adopt mode: reference a public hosted zone this account does not own. Nothing is built —
# the zone's id and name servers are resolved from adopt_zone_id via a read-only data source,
# and the outputs re-export them so a consumer wires against the same interface it uses in
# create mode.
#
# The data source carries the consumer-side adopt preflight: an assertion that runs at plan and
# fails there, not silently at a later consumer. What CAN be asserted from the referencing side
# is asserted hard — the resolved zone's name must equal domain_name, so an adopt_zone_id that
# points at the wrong zone is caught at plan rather than surfacing as a wrong external-dns
# domain filter or a cert validated against the wrong zone downstream.

data "aws_route53_zone" "adopt" {
  count   = local.adopt_mode ? 1 : 0
  zone_id = var.adopt_zone_id

  lifecycle {
    postcondition {
      # Route53 returns zone names with a trailing dot; normalize before comparing.
      condition     = trimsuffix(self.name, ".") == var.domain_name
      error_message = "adopt_zone_id (${var.adopt_zone_id}) resolves to zone '${trimsuffix(self.name, ".")}', not domain_name (${var.domain_name}). The adopted zone must be the one for this component's domain."
    }
  }
}

locals {
  # Single interface across both modes: outputs read these, so a consumer sees one shape whether
  # the zone was built here (create) or resolved from elsewhere (adopt).
  resolved_zone_id           = local.create_mode ? aws_route53_zone.primary[0].zone_id : data.aws_route53_zone.adopt[0].zone_id
  resolved_zone_name_servers = local.create_mode ? aws_route53_zone.primary[0].name_servers : data.aws_route53_zone.adopt[0].name_servers
}
