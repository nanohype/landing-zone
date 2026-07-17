# shared-network

The owner side of the cross-account **adopt** topology. A central network-owner account runs
this component to build one shared VPC per environment and RAM-share its subnets to the
workload accounts that adopt them.

## Where it sits

Three account roles, two RAM hops:

```
management account            network-owner account          workload account
  org-networking      ──RAM──▶  shared-network       ──RAM──▶  network (adopt mode)
  (TGW + IPAM top       IPAM     (this component)      subnets   cluster
   pool + env sub-pools) pool                                    (stamp_subnet_tags=false)
```

- **Hop 1** — `org-networking` (management account) shares the IPAM env sub-pool (and, when
  centralized egress is used, the transit gateway) to the network-owner account.
- **Hop 2** — `shared-network` (this component) shares its subnets to one or more workload
  accounts. Each workload account runs the `network` component in `adopt` mode against those
  subnet IDs, and a `cluster` with `stamp_subnet_tags = false`.

One network-owner account holds per-environment VPCs
(`live/aws/network/us-west-2/{development,staging,production}/shared-network`), each sharing
to its matching `workload-<env>` account. Account-per-environment is a live-tree layout
choice at activation time, not a component change.

## The contract

This is the operational hand-off between owner and consumer. The workload account's `network`
adopt preflight asserts the participant-observable half at `plan`; this component and this
document own the half a participant cannot see.

### Endpoints (owner-run, participant cannot verify)

`shared-network` runs the full private endpoint set an EKS cluster and its addons need over
the data path, via the shared `modules/aws/eks-vpc-endpoints` module — the same set the
create-mode `network` component builds, so an owned VPC and an adopted VPC are identical:

| Endpoint | Type | Purpose |
|----------|------|---------|
| `s3` | Gateway | image layer / artifact pulls, associated with every shared route table |
| `ecr_api`, `ecr_dkr` | Interface | container image pulls |
| `secretsmanager` | Interface | external-secrets, app secrets |
| `ssm` | Interface | SSM parameter reads, session manager |
| `sts` | Interface | regional STS for IRSA web-identity tenants |
| `eks_auth` | Interface | EKS Pod Identity (`eks-auth.<region>.amazonaws.com`) |
| `aps_workspaces` | Interface | Amazon Managed Prometheus remote_write + queries |
| `eks` | Interface | EKS API — **conditional** (`enable_eks_interface_endpoint`) |

A participant account **cannot** `DescribeVpcEndpoints` on these (they live in the owner's
account), so interface-endpoint completeness is not assertable from the consumer side. It
rides this component's `checks.tf` `endpoint_set_complete` assertion plus real DNS resolution
at cluster bootstrap. The `eks` endpoint is excluded from the required set because a
provisioning hub deliberately turns it off (its private DNS would otherwise shadow the OIDC
issuer subdomain).

### Route tables (participant-observable)

Every **private** route table carries, and the consumer's adopt preflight asserts by exact
match:

- a route to the region's AWS-managed **S3 gateway prefix list**
  (`com.amazonaws.<region>.s3`) — the S3 gateway endpoint installs this into each associated
  route table. A DynamoDB or other gateway route does **not** satisfy the contract.
- a **default egress route** (`0.0.0.0/0`) with a **live target** — a NAT gateway (local
  egress) or the transit gateway (centralized egress). A blackholed default route (e.g. left
  behind by a deleted NAT) does **not** satisfy the contract.

**Explicit route-table associations are mandatory.** The consumer preflight's
`data.aws_route_table` lookup keys on `subnet_id` and only matches a subnet with an
**explicit** route-table association — a subnet riding the VPC's implicit *main* route table
returns a generic provider error instead of a clear contract-violation message. This
component, built on `terraform-aws-modules/vpc`, already associates every subnet explicitly
and so complies. This requirement is guidance for anyone hand-rolling a different owner
network against the same contract: associate every shared subnet with an explicit route
table.

### Subnet role tags (cluster-agnostic)

Shared subnets carry only the ELB scheduling tags:

- public subnets: `kubernetes.io/role/elb = 1`
- private subnets: `kubernetes.io/role/internal-elb = 1`

There is deliberately **no** `kubernetes.io/cluster/<cluster>` ownership tag. A shared VPC is
bound to no single cluster, and AWS RAM does not surface owner-written tags to participants
anyway — so cross-account consumers select subnets by **explicit ID** (the `network`
component's `adopt_private_subnet_ids` / `adopt_public_subnet_ids` inputs), never by
discovery tag. The role tags exist for same-account participants and as the owner's own
authoritative convention.

### RAM share scope

- **Private** subnets are always shared. **Public** subnets are shared only when
  `share_public_subnets = true` (needed for internet-facing load balancers in the adopting
  cluster). Intra subnets are never shared.
- The share is `allow_external_principals = false` — it resolves only for principals inside
  the owner's AWS Organization.
- Principals are the account IDs in `consumer_account_ids`.

## Consuming this VPC (workload account)

Read the shared VPC's facts (this component publishes them to the owner account's SSM under
`/platform/<env>/shared-network/*`, or take them from `terraform output`) and wire the
`network` component in `adopt` mode:

```hcl
# workload account, network leaf
inputs = {
  network_mode             = "adopt"
  adopt_vpc_id             = "vpc-0123..."            # shared-network vpc_id
  adopt_private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
  adopt_public_subnet_ids  = ["subnet-x", "subnet-y", "subnet-z"]
}
```

The paired `cluster` leaf then derives `stamp_subnet_tags = false` from the network leaf's
`network_mode` automatically — a participant cannot tag a subnet it does not own.

## Activation and teardown prerequisites

There is no automated activation or unshare path; both are manual, per-engagement steps.

**Before the share resolves:**

- **Enable resource sharing with AWS Organizations.** `allow_external_principals = false`
  shares only reach principals outside the owner's own account tree once org-wide sharing is
  enabled in RAM (`aws ram enable-sharing-with-aws-organizations`, run once per org). Without
  it, a principal association to another org account silently never resolves.
- The IPAM env sub-pool must already be RAM-shared to this network-owner account by
  `org-networking` (set its `ram_principals` to include this account). This component
  discovers the pool by its `org-ipam-<environment>` tag, or takes an explicit `ipam_pool_id`
  override.

**Before tearing a share down** (order matters — RAM will not let you unshare a subnet with
live consumer ENIs, and forcing it orphans state):

1. Drain the consumer side first — cordon/drain and delete the adopting cluster's nodes and
   any load balancers so no ENIs remain in the shared subnets.
2. Remove the consumer from `consumer_account_ids` (revokes the principal association).
3. Only then destroy or re-CIDR the shared VPC.

## Inputs (selected)

| Input | Default | Notes |
|-------|---------|-------|
| `ipam_pool_id` | `""` | empty = discover the env sub-pool by tag; set to pin explicitly |
| `ipam_netmask_length` | `16` | 16–20; subnets carve 8 bits smaller (min /28) |
| `nat_gateways` | `1` | 1/2/3 by environment; ignored under `centralized_egress` |
| `transit_gateway_id` | `""` | required when `centralized_egress = true` |
| `centralized_egress` | `false` | route default egress via TGW instead of local NAT |
| `enable_vpc_endpoints` | `true` | build the private endpoint set |
| `consumer_account_ids` | `[]` | workload accounts to RAM-share to |
| `share_public_subnets` | `false` | also share public subnets |

## Testing

`tofu test` (`tests/shared-network.tftest.hcl`) covers, against a mocked provider: the
local-NAT owner VPC (endpoints + role tags + RAM share), the centralized-egress owner VPC (0
NAT gateways + TGW default route), both contract-check violations (dropped endpoints, empty
consumers), the IPAM carving-base pin holding across a day-2 preview shift, and the netmask
range guard.
