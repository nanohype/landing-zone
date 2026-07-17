# egress-network

The central-egress hub — the receiving end of centralized egress. When a spoke VPC flips
`centralized_egress` (the create-mode `network` component, or a `shared-network` owner VPC),
it stops running local NAT and points its private default route (`0.0.0.0/0`) at the org
transit gateway. This component terminates that traffic on the far side of the TGW and
carries it to the internet: a small VPC with NAT gateways, a TGW attachment, and the return
routing that makes the whole path work.

Without it, flipping `centralized_egress` blackholes egress — the spoke sends its default
route to the TGW and nothing there forwards it anywhere.

## Where it sits

```
spoke VPC (network / shared-network)        org TGW (org-networking)        egress hub (this)
  0.0.0.0/0 -> TGW  ──────────────────────▶  default route table    ──────▶  private subnet
                                              static 0.0.0.0/0 route            -> NAT -> IGW
                                              -> egress attachment                -> internet
```

One central network-owner account runs both the shared VPCs (`shared-network`) and this
egress hub. The org transit gateway itself is owned by `org-networking` in the management
account and RAM-shared to this account.

## One hub per transit gateway

There is exactly **one** egress hub per TGW, because the static `0.0.0.0/0` route that steers
every spoke's default egress lives in the TGW's single default route table, and a route table
holds exactly one `0.0.0.0/0` entry. A second egress hub attaching to the same TGW and
competing for that route is a footgun — the two would fight over the one default route.

The org runs a single transit gateway (`org-networking`, one deployment in the management
account, RAM-shared org-wide), so there is a single egress hub across all environments. This
component is therefore instantiated once (under the `hub` slot in the network account), not
per environment — every spoke that flips `centralized_egress`, in any environment, egresses
through this one hub. Per-environment egress isolation would require `org-networking` to grow
per-environment TGW route tables and associate each environment's spoke attachments to its
own table; that is a deliberate future addition, not something this component can do from a
participant account.

### Shared-hub blast radius

One hub across all environments means development, staging, and production **share this hub's
NAT gateways** — both their public source IPs and their port capacity:

- **Shared source IPs.** Every environment's outbound traffic leaves from the same NAT gateway
  Elastic IPs, so a third party cannot allowlist "production only" by egress IP — dev and
  staging present the same addresses. If per-environment egress-IP allowlisting is a
  requirement, that needs per-environment egress hubs (the per-env TGW route table addition
  above), not a shared one.
- **Shared port capacity.** A NAT gateway has a finite pool of simultaneous connections per
  destination. A runaway non-production workload (a load test, a retry storm) that saturates
  the NAT gateways can degrade production egress through the same hub — there is no
  per-environment isolation of NAT capacity here. Size the hub for the aggregate and keep an
  eye on the NAT `ErrorPortAllocation` metric; move to per-environment hubs if non-prod noise
  starts to threaten prod egress.

## Split responsibility: why the static route is not here

This component builds everything a TGW **participant** is permitted to build:

- the egress VPC, its public + NAT-facing private subnets, and the NAT gateways;
- the cross-account TGW **attachment** on the private subnets;
- the **return route** (`spoke_supernet_cidr -> TGW`) on the public route tables, so
  NAT-translated replies find their way back to the originating spoke.

It does **not** build the static `0.0.0.0/0` route in the TGW's route table. Per AWS's
[shared transit gateway documentation](https://docs.aws.amazon.com/vpc/latest/tgw/transit-gateway-share.html)
("Shared transit gateways"):

> When a transit gateway is shared with you, you cannot create, modify, or delete its transit
> gateway route tables, or its transit gateway route table propagations and associations.

A participant may only *create and describe attachments* and *describe the transit gateway* —
running the transit gateway route table APIs is reserved to the owner. So the static default
route is created by **`org-networking`** (the TGW owner, management account), which exposes an
`egress_tgw_attachment_id` input for exactly this. This component publishes
`tgw_attachment_id` for the owner to target.

For the same reason, the attachment leaves
`transit_gateway_default_route_table_association` and
`transit_gateway_default_route_table_propagation` **unset** rather than configuring them.
The AWS provider gates the owner-side association/propagation call behind an owner-ID check:
on a shared TGW it skips that call entirely at create (a participant has no permission to run
it), then reports both attributes as `true` on read. Configuring either as `false` therefore
prevents nothing — it just pins a permanent `true -> false` diff on every plan, and applying
that diff hits the provider's unconditioned update path, which does call the owner-only
disassociate/disable API from this participant account and fails (a recurring, unfixable drift
finding under this repo's scheduled drift detection). Left unset, the attributes produce no
diff. The owner's TGW (with default association + propagation and
`auto_accept_shared_attachments` all enabled) auto-accepts the attachment and associates +
propagates it into the default route table from the owner side.

## The full path, traced

- **Forward.** A spoke with `centralized_egress = true` routes `0.0.0.0/0 -> TGW`. The
  spoke's attachment is associated with the TGW default route table, whose static
  `0.0.0.0/0` route (owned by `org-networking`) targets this hub's attachment. Traffic lands
  in a NAT-facing private subnet, whose route table sends `0.0.0.0/0 -> NAT`; NAT forwards to
  the internet gateway.
- **Return.** Replies arrive at the NAT gateway (in a public subnet). The public route table
  carries `spoke_supernet_cidr -> TGW`, so NAT-translated replies go back to the TGW, whose
  default route table has every spoke's CIDR propagated (by the spoke attachments) and routes
  each reply to the correct spoke.

The spoke side is the `network` / `shared-network` `centralized_egress` lever
(`aws_route.tgw_default_egress`, `0.0.0.0/0 -> TGW`); the hub + return side is here; the
static default route is in `org-networking`. The three compose into a complete path, none
creating another's resources.

## Address space

The egress VPC uses a **dedicated** CIDR (`egress_vpc_cidr`, default `100.64.0.0/24`), NOT
workload IPAM space. It must sit outside the org workload supernet (`spoke_supernet_cidr`,
default `10.0.0.0/8`) so it never overlaps a spoke drawn from the org IPAM pools — an overlap
would break TGW routing. Carrier-grade NAT space (`100.64.0.0/10`, RFC 6598) is the
recommended home. `checks.tf` carries a bidirectional overlap check (it catches either CIDR
nested inside the other). Like every tofu `check` block it only *warns* at a real `plan` /
`apply` — it does not hard-fail an operator's apply — but a `tofu test` run treats a failing
check as a hard failure (the suite gates it via `expect_failures`), so an overlapping change
cannot merge through CI even though it would not block a live apply.

## Activation sequence

1. `org-networking` (management account) is deployed with the TGW, and its `ram_principals`
   includes this network-owner account so the TGW is RAM-shared here.
2. Deploy this hub with `transit_gateway_id` set to the org TGW — it builds the VPC, NAT, and
   the attachment (auto-accepted by the owner TGW), and outputs `tgw_attachment_id`.
3. Set `org-networking`'s `egress_tgw_attachment_id` to that attachment ID and apply
   `org-networking` — the owner adds the static `0.0.0.0/0` route to the TGW default route
   table, and centralized egress is live for every spoke that flips the lever.

Step 3 is a manual cross-account wiring step (the network account and the management account
do not read each other's state), mirroring how `shared-network` receives its IPAM pool over
RAM rather than through repo state.

## Teardown

AWS enforces nothing at detach or route-removal time. Removing the static route (clearing
`org-networking`'s `egress_tgw_attachment_id`) or deleting the attachment applies cleanly
whether or not spokes are still routing default egress here — the danger surfaces later, on
the spoke side, as blackholed egress the moment the route is gone. Ordering is operator
discipline, not an AWS backstop:

1. Move every spoke off centralized egress first (flip `centralized_egress = false` so it
   restores local NAT), or accept that those spokes lose internet egress.
2. Then clear `org-networking`'s `egress_tgw_attachment_id` (removes the static route) and
   destroy this hub.

## Inputs (selected)

| Input | Default | Notes |
|-------|---------|-------|
| `egress_vpc_cidr` | `100.64.0.0/24` | dedicated infra space, /16–/24, outside the supernet |
| `spoke_supernet_cidr` | `10.0.0.0/8` | org workload supernet; the return route target |
| `transit_gateway_id` | (required) | the org TGW, RAM-shared to this account |
| `nat_gateways` | `1` | 1 (single) or `max_azs` (per-AZ HA); ties to subnet count |
| `enable_flow_logs` | `false` | egress traffic visibility |

## Outputs (selected)

| Output | Notes |
|--------|-------|
| `tgw_attachment_id` | feed into `org-networking`'s `egress_tgw_attachment_id` |
| `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `nat_gateway_ids` | the built hub |

## Testing

`tofu test` (`tests/egress-network.tftest.hcl`) covers, against a mocked provider: the default
hub (VPC + single NAT + cross-account TGW attachment with appliance mode on + the spoke return
route), per-AZ NAT, the in-between `nat_gateways` rejection, the CIDR-overlaps-supernet
contract check in both directions (egress inside the supernet, and the reverse — a supernet
nested inside a wider egress CIDR), and a malformed `spoke_supernet_cidr` rejected by variable
validation.
