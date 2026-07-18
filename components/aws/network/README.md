# network

The per-environment network foundation every workload cluster lands on. One component, two
modes: it either **owns** a VPC (`create`) or **participates** in one it does not own
(`adopt`). Both modes expose the identical output interface, so a consuming `cluster` wires
against one contract regardless of who owns the VPC.

## Where it sits

```
org-networking (mgmt acct)      network / shared-network        cluster / workloads
  TGW + IPAM top pool    ──RAM──▶  network (create)      ──────▶  cluster
  + env sub-pools                  or shared-network              (stamp_subnet_tags
                                   (adopt's owner side)            derived from mode)
                                        │
                        centralized_egress │ 0.0.0.0/0 -> TGW
                                        ▼
                                   egress-network (central egress hub)
```

- **create** — this component builds the VPC: subnets, endpoints, egress, and the ELB role
  tags. The single-account default.
- **adopt** — this component builds nothing. It resolves an existing VPC (same-account, or
  shared cross-account via AWS RAM by `shared-network`) and re-exports its facts through the
  same outputs. The owner (`shared-network`) runs the VPC, endpoints, and subnet tagging.

The mode is set per leaf via `network_mode`; every `live/.../network/terragrunt.hcl` picks
one. The paired `cluster` leaf derives `stamp_subnet_tags` from the network leaf's
`network_mode` output — a participant cannot tag a subnet it does not own.

## create mode

The default. Builds a VPC (via `terraform-aws-modules/vpc`) with:

- **CIDR** from either a literal `vpc_cidr` (default `10.0.0.0/16`) or an IPAM pool
  (`ipam_pool_id` + `ipam_netmask_length`). The two are mutually exclusive — variable
  validation rejects setting both. Cross-account, the pool is the org IPAM env sub-pool
  shared in over RAM by `org-networking`.
- **Subnets** — public + private tiers, one per AZ across `max_azs` (default 3), carved 8
  bits smaller than the VPC block (`cidrsubnet(base, 8, …)`).
- **Egress** — local NAT (`nat_gateways` = 1 shared, or `max_azs` for per-AZ HA; an
  in-between count is rejected because the upstream module ties NAT count to subnet count),
  or **centralized egress** through the transit gateway (`centralized_egress = true`, zero
  NAT, the private default route points at the TGW — see `egress-network` for the far side).
- **VPC endpoints** — the full private set an EKS cluster needs, via the shared
  `modules/aws/eks-vpc-endpoints` module (the same set `shared-network` runs, so an owned VPC
  and an adopted VPC are identical). `enable_eks_interface_endpoint` defaults on; turn it
  **off** for an eks-fleet provisioning hub, whose EKS endpoint private DNS would otherwise
  shadow the IRSA OIDC issuer subdomain (`oidc.eks.<region>.amazonaws.com`) and break
  `data.tls_certificate` when the in-VPC runner provisions a spoke's OIDC provider.
- **Flow logs** — `enable_flow_logs` (default `false`; the leaves set it explicitly —
  staging/production on, development off).
- **ELB role tags** — `kubernetes.io/role/elb` (public) and `.../internal-elb` (private).
  The per-cluster `kubernetes.io/cluster/<cluster>` ownership + Karpenter-discovery tags are
  **not** here — the VPC is shared per environment and cluster-agnostic, so each co-located
  cluster stamps its own via the `cluster` component.

### The IPAM carving pin

When drawing from an IPAM pool, the "next CIDR" preview re-evaluates on every plan, so
carving subnets straight off it would shift every subnet to a destructive replacement on the
next plan (and the new blocks would not even fit the VPC's already-allocated CIDR). A
`terraform_data` resource pins the previewed base in state with `ignore_changes = [input]`,
so the carving base stays fixed at its first-applied value regardless of later previews. A
single-writer IaC flow is the assumed model, matching the org's per-account, per-environment
VPC ownership.

### Transit gateway

Setting `transit_gateway_id` places a TGW attachment on the private subnets and adds a
`10.0.0.0/8 -> TGW` route to every private route table so the VPC reaches the rest of the
org's address space. It requires an IPAM-allocated CIDR — a raw literal `/16` can overlap
another attached VPC and break TGW routing, so the combination is rejected at variable
validation. `centralized_egress` layers a `0.0.0.0/0 -> TGW` route on top and drops local
NAT.

## adopt mode

`adopt` participates in a VPC this account does not own. It builds nothing — `adopt_vpc_id`,
`adopt_private_subnet_ids`, and `adopt_public_subnet_ids` (public may be empty for a
private-only cluster) are resolved through read-only data sources and re-exported through the
same outputs `create` produces.

Those data sources carry the **consumer-side adopt preflight**: assertions that run at plan
and fail there, not silently at cluster-Ready. This is the participant-observable half of the
contract `shared-network` (or any owner network) must satisfy:

| Preflight assertion | Guards against |
|---------------------|----------------|
| every adopted subnet resides in `adopt_vpc_id` | a stray subnet ID from the wrong VPC |
| every private route table routes the region's **exact** S3 gateway prefix list (`com.amazonaws.<region>.s3`) | a missing S3 path (matching *any* prefix list would also accept a DynamoDB route while S3 pulls silently fall to NAT) |
| every private route table has a `0.0.0.0/0` route with a **live target** (NAT or TGW) | a blackholed default route left by a deleted NAT — the destination shows but reaches nothing |
| the private subnets span at least `max_azs` zones | a node group that cannot spread across the AZs the environment expects |

What the preflight **cannot** assert: a participant cannot `DescribeVpcEndpoints` on the
owner's foreign interface endpoints, so interface-endpoint completeness rides the owner's
contract (`shared-network`'s own `check` blocks + README) plus real DNS resolution at cluster
bootstrap. See `components/aws/shared-network/README.md` for the owner side of this contract.

## Consuming this component

`cluster` (and the workload components) read `network`'s outputs through a terragrunt
`dependency` block (`live/_envcommon/aws/cluster.hcl`), not SSM — `network` publishes no SSM
parameters (the owner-side `shared-network` publishes its own facts to `/platform/<env>/shared-network/*`
for that account's automation). The two outputs a cross-account consumer must handle
carefully:

- **`network_mode`** — the `cluster` leaf derives `stamp_subnet_tags` from it (create ⇒ tag,
  adopt ⇒ defer to the owner).
- **`private_subnet_az_ids` / `public_subnet_az_ids`** — AZ **IDs** (`usw2-az1`), not names.
  AZ names map to different physical zones per account, so a cross-account consumer must key
  on the IDs.

## Inputs (selected)

| Input | Default | Notes |
|-------|---------|-------|
| `network_mode` | `create` | `create` (own a VPC) or `adopt` (participate in one) |
| `vpc_cidr` | `10.0.0.0/16` | create, literal allocation; mutually exclusive with `ipam_pool_id` |
| `ipam_pool_id` | `""` | create, draw the CIDR from an IPAM pool instead |
| `ipam_netmask_length` | `0` | required (16–20) with a pool; subnets carve 8 bits smaller (min /28) |
| `transit_gateway_id` | `""` | create, attach to the org TGW (requires an IPAM CIDR) |
| `centralized_egress` | `false` | create, route egress via TGW to the egress hub (requires a TGW) |
| `max_azs` | `3` | zones spanned |
| `nat_gateways` | `1` | `1` (shared) or `max_azs` (per-AZ HA); 0 under centralized egress |
| `enable_flow_logs` | `false` | create; the owner logs an adopted VPC |
| `enable_vpc_endpoints` | `true` | create; the owner runs endpoints on an adopted VPC |
| `enable_eks_interface_endpoint` | `true` | create; set `false` for an eks-fleet provisioning hub |
| `adopt_vpc_id` | `""` | adopt, required — the VPC to participate in |
| `adopt_private_subnet_ids` | `[]` | adopt, required non-empty |
| `adopt_public_subnet_ids` | `[]` | adopt, optional (empty = private-only) |

Create-mode levers reject `adopt` mode and vice-versa — a field from the wrong side is a
contradiction, rejected at variable validation, not silently ignored.

## Outputs (selected)

| Output | Notes |
|--------|-------|
| `network_mode` | the mode this leaf ran in; the cluster derives subnet-tag ownership from it |
| `vpc_id`, `vpc_cidr_block` | resolved identically in both modes |
| `private_subnet_ids`, `public_subnet_ids` | the subnets a cluster schedules across |
| `private_subnet_az_ids`, `public_subnet_az_ids` | cross-account-stable AZ IDs (pair with the name outputs) |
| `private_route_table_ids` | **not** 1:1 with subnets — de-duplicate before assuming a per-subnet relationship |
| `nat_gateway_ids` | empty under centralized egress or in adopt mode |
| `vpc_endpoints_sg_id` | `null` in adopt mode (the owner runs endpoints) |

## Testing

`tofu test` (`tests/network.tftest.hcl`) covers, against a mocked provider: create default,
create + IPAM (with the carving-base pin holding across a day-2 preview shift), create + TGW +
centralized egress (zero NAT, default route to the TGW), the adopt happy path, and each
preflight failure (subnet in the wrong VPC, a missing S3 gateway route, a non-S3 prefix-list
route, a blackholed default route), plus the mode-conflict rejections, the IPAM netmask range
guard, and the in-between `nat_gateways` rejection.
