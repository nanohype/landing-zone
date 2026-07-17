# Network idiom — landing-zone

Tactical plan for this repo's targets in the network-idiom campaign. Master plan:
`~/.claude/plans/network-idiom.md` (decision ledger N1-N4 settled there — N1
discriminated create/adopt schema, N2 full cross-account topology built now, N3
additive TGW/IPAM levers default-off, N4 IPv6 deferred).

**Nothing is deployed today** — no live cluster, no live `Cluster` CR anywhere.
Design for the cleanest shape; no migration/backward-compat framing anywhere in code,
comments, or docs (greenfield doctrine).

## Status

| # | target | status |
|---|---|---|
| 1 | network + cluster mode-aware; create IPAM/TGW levers; shared endpoint module; adopt preflight | ✅ |
| 2 | IP + auth hygiene on cluster addon config | ✅ |
| 1-fix | adopt preflight precision + validation gaps + IPAM day-2 replan bug (Fable review) | ✅ |
| 3 | `shared-network` owner component + RAM share + contract | ✅ |
| 3b | `egress-network` owner component (central-egress VPC + TGW static default route) | ⬜ |
| 4 | cluster-bootstrap publishes network_mode + adopt subnet IDs (public + private) | ⬜ |

Run these **serialized, in order** (1 → 2 → 1-fix → 3 → 3b → 4) — never two agents in
this repo concurrently. Every target ends in a PR (never a direct push to `main`,
even though this repo's branch protection allows an admin bypass), CI green (poll
`gh pr checks` synchronously in the foreground — no backgrounded `--watch`, no ending
your turn to wait on it), then squash-merge.

**Second independent review pass (Fable, reviewing the plan itself, not any
implementation) landed after Target 2 merged.** Three real findings folded into the
sequence below: (1) the IPAM preview-CIDR pattern Target 1 shipped has a confirmed
upstream day-2 replan bug — folded into Target 1-fix as item 7; (2) `centralized_egress`
had no owner-side receiving end anywhere in the original 7-target plan — resolved
(greenfield, no live risk from building it now; matches this campaign's N2 precedent
of building complete rather than deferred) as new **Target 3b**; (3) adopt-mode LB
injection was public-subnet-blind — folded into Target 4 (publish both subnet CSVs)
and Target 6 (scheme-aware Kyverno mutation). Full review detail: ask for the Fable
plan-review transcript if you need the reasoning behind any of these, but treat the
findings below as settled, not open questions.

---

## Target 1-fix — adopt preflight precision + validation gaps (S)

**Shipped.** All eight findings landed in `components/aws/network` (+ the terragrunt
`cluster` envcommon and the `fleet/aws/cluster-stack` outputs). Resolution decisions
worth recording:
- **Item 2 cap = /20, not /24.** The raw `cidrsubnet` error ceiling is /24, but a /24
  base carves /32 subnets AWS also rejects. /20 is the real floor — the smallest base
  whose newbits-8 carving still yields /28 subnets (AWS's minimum) across all three
  tiers. Validated range is now 16–20.
- **Item 3 validations sit on each field, not on `network_mode`.** Anchoring both
  halves on `network_mode` (referencing the `adopt_*` variables) formed a validation
  cycle, since those variables reference `network_mode` back. Each create-mode lever
  rejects `adopt`, and each `adopt_*` input rejects `create`, one-directionally.
- **Item 7 uses the `terraform_data` pin, not `aws_vpc_ipam_pool_cidr_allocation`.** The
  `terraform_data` pin integrated cleanly with the upstream module's `use_ipam_pool`
  inputs, so the AWS-docs alternative wasn't needed. Exact shape recorded in the "Note
  from Target 1-fix" under Target 3.
- **Item 8 outputs are also re-exported from `fleet/aws/cluster-stack`** so Target 5
  (eks-fleet) can reach them — see the Target 3 note.

**Depends on:** Target 2 (serialized after it in this repo — already merged, so this
is next). **Blocks Target 3** — Target 3's `shared-network` README documents the
exact contract this preflight checks; that documentation needs to describe accurate
behavior, not the current looser-than-intended one.

**Context:** an independent post-merge review (Fable, adversarial, ran real probe
fixtures against a scratchpad copy of the component — repo itself untouched) found
four confirmed defects in Target 1's adopt-mode preflight and validation logic.
These are real, execution-verified findings, not style preferences — fix them
before Target 3 builds on this foundation.

**Findings (confirmed via execution):**

1. **The S3-gateway-route assertion in `adopt.tf` matches too loosely.** It currently
   accepts *any* route with a non-empty `destination_prefix_list_id` as proof the S3
   gateway route exists — a probe fixture with only a DynamoDB-shaped prefix-list
   route (no S3 route at all) passed the preflight. Similarly, the default-egress
   assertion accepts *any* route with destination `0.0.0.0/0` regardless of its
   target — a probe fixture with a blackholed default route (empty target, e.g. from
   a deleted NAT) also passed. Concrete failure: an owner network missing the S3
   gateway route, or with a dead default route, plans clean in `adopt` mode and only
   fails later at cluster bootstrap — exactly the silent-until-cluster-Ready failure
   class this preflight exists to prevent.
2. **`ipam_netmask_length` validation (`variables.tf`) accepts 16-28, but subnet
   carving is fixed at `newbits=8`** — anything above 24 passes validation then dies
   with a raw, unhelpful `cidrsubnet` "insufficient address space" provider error.
   Cap the validated range at 24 (or lower, since a /24 base yields /32 subnets —
   pick a floor that leaves room for `max_azs` × 3 subnet tiers).
3. **`network_mode=adopt` silently ignores create-mode levers instead of rejecting
   the combination.** Setting `network_mode=adopt` together with `ipam_pool_id`,
   `transit_gateway_id`, or `centralized_egress=true` plans clean — every lever is
   silently no-op'd (all gate on `local.create_mode`). Symmetric case (`create` mode
   with `adopt_*` fields set) is also silently ignored. This contradicts the
   component's own stated design posture (documented at `variables.tf` near the
   mode field: reject contradictory input, don't silently ignore one side of it).
   Add validation blocks rejecting cross-mode field combinations.
4. **`stamp_subnet_tags` is only auto-derived from `network_mode` on the fleet path**
   (`fleet/aws/cluster-stack/main.tf`), not on the terragrunt live-tree path
   (`live/_envcommon/aws/cluster.hcl`). A terragrunt-driven adopt cluster requires an
   operator to manually set both `network_mode=adopt` on `network` AND
   `stamp_subnet_tags=false` on `cluster` — miss the second one and a cross-account
   `apply` fails late with `UnauthorizedOperation` on `CreateTags`, the exact
   late-failure class the preflight was built to kill. Wire
   `live/_envcommon/aws/cluster.hcl` to derive `stamp_subnet_tags` from the
   network dependency's `network_mode` output, matching the fleet path's pattern —
   don't leave this as a two-knob manual contract.
5. **Minor:** `outputs.tf`'s comment claiming private route tables are "one per
   private subnet" is false in create mode with `nat_gateways=1` (one shared table)
   and can return duplicates in adopt mode. Fix the comment; note for whoever
   implements Targets 4/5 status plumbing that it shouldn't assume a 1:1 subnet-to-
   route-table relationship.
6. **Also fix the temporal-framing doctrine nit** flagged in the same review:
   `network/variables.tf`'s `network_mode` description parenthetical "(the default;
   today's only behavior)" reads as accreted, not designed — reword to describe the
   end state plainly (e.g. just "the default" or similar, no "today's only" framing).
7. **The IPAM preview-CIDR pattern has a confirmed day-2 replan bug** (from the
   second review pass, reviewing the plan/design rather than re-testing the merged
   code — but this is a real, citable upstream defect, not a guess).
   `data.aws_vpc_ipam_preview_next_cidr` (used in `main.tf` for the create+IPAM
   path) re-evaluates on every plan. Once the VPC actually allocates the previewed
   block, the *next* plan previews a different (the next free) CIDR, so
   `subnet_base_cidr` shifts and every subnet plans as a destructive replacement —
   which can't even apply, since the new subnet CIDRs don't fit inside the VPC's
   already-allocated block. This is a known upstream issue
   (terraform-aws-modules/vpc#980, "forcing changes on subsequent runs"); the AWS
   provider's own docs for this data source recommend `lifecycle { ignore_changes }`,
   which can't be attached to subnet resources living inside the third-party VPC
   module. It's latent today (nothing sets `ipam_pool_id` yet), but Target 3b and any
   future IPAM-mode `create` deployment hits it on the very first day-2 plan, and
   this repo runs scheduled drift detection that would trip on it immediately.
   **Fix:** pin the carving base in state — a `terraform_data` resource whose
   `input` is the previewed CIDR with `lifecycle { ignore_changes = [input] }`, then
   carve subnets and the endpoint-SG CIDR off its `output` instead of the raw data
   source. (The alternative — an explicit `aws_vpc_ipam_pool_cidr_allocation`
   resource with the same `ignore_changes` treatment — is the AWS-docs-blessed path
   if the `terraform_data` pin proves awkward with the upstream VPC module's input
   shape; use whichever integrates more cleanly, but ship one of them, not the raw
   preview.)
8. **AZ names aren't cross-account-stable; AZ IDs are.** `outputs.tf`'s
   `private_subnet_azs`/`public_subnet_azs` (added in Target 1) expose AZ *names*
   (e.g. `us-west-2a`) via `local.azs`/`data.aws_availability_zones`. AZ names map to
   different physical AZs per AWS account (by design); AZ *IDs* (e.g. `usw2-az1`) are
   the only cross-account-consistent identifier — EKS's own shared-subnet
   documentation calls this out explicitly. This is fine as long as these outputs
   stay same-account, but Target 5 (eks-fleet) is about to surface them as
   `status.subnetAzIds` on a cross-account-relevant API. Add
   `private_subnet_az_ids`/`public_subnet_az_ids` outputs (via
   `data.aws_subnet.*.availability_zone_id`, keyed off the existing subnet ID
   outputs) alongside the existing name-based ones — don't remove the names (same-
   account consumers may still want them for readability), just add the IDs as the
   field Target 5 should actually thread into `status.subnetAzIds`.

**Not required in this target, but read Target 3's spec for it:** the review's
finding that `data.aws_route_table` (keyed on `subnet_id`) only matches explicit
route-table associations, not a subnet riding the VPC's implicit main route table —
producing a generic provider error instead of a contract-violation message for a
hand-built (non-terraform-aws-modules) owner network. This is being handled as a
Target 3 contract requirement (mandate explicit associations in the `shared-network`
README) rather than a Target 1 code change, since the module-built owner network
Target 3 ships is already compliant.

**Approach:** fix items 1-8 directly in `components/aws/network/adopt.tf`,
`variables.tf`, `outputs.tf`, `main.tf` (item 7's IPAM pinning), and
`live/_envcommon/aws/cluster.hcl`. For item 1, use
`data.aws_ec2_managed_prefix_list` (filtered on the AWS-managed S3 prefix list name
for the target region, `com.amazonaws.<region>.s3`) to assert the *exact* prefix
list ID is routed, and require the default-egress route's target (NAT gateway ID or
TGW attachment ID) to be non-empty, not just the destination CIDR.

**Acceptance:**
- Re-run the review's three probe scenarios (or equivalent new test cases added to
  `components/aws/network/tests/network.tftest.hcl`) and confirm each now fails at
  `plan` with a clear message: (a) owner route table missing the S3 gateway route
  entirely, (b) owner default route present but with an empty/blackholed target,
  (c) `adopt` mode with a create-mode lever set (and the symmetric `create` +
  `adopt_*` case).
- `ipam_netmask_length=26` (or any value >24) fails at `tofu validate`/plan with the
  variable's own validation message, not a raw `cidrsubnet` provider error.
- A terragrunt render/plan against a `cluster` live leaf shows `stamp_subnet_tags`
  correctly derived from the paired `network` leaf's `network_mode` — no manual
  second knob required.
- **Day-2 replan test for item 7**: a `tofu test` fixture that plans create+IPAM
  twice in sequence with the same inputs (simulating post-apply drift-check
  behavior) shows the second plan as a no-op for the subnet/SG resources — not a
  replacement. If the test harness can't simulate a real IPAM allocation between
  plans, at minimum confirm via `tofu plan` twice against the same fixture state
  that the previewed CIDR itself isn't re-read into the subnet calculation on the
  second pass (i.e. the `terraform_data`/`aws_vpc_ipam_pool_cidr_allocation` pin is
  actually load-bearing, not decorative).
- **Item 8**: `private_subnet_az_ids`/`public_subnet_az_ids` outputs exist and
  resolve to AWS AZ IDs (`usw2-az1`-shaped values), not AZ names, verifiable via
  `tofu plan` output on a fixture with known mock AZ IDs.
- `task fmt:check`, `task validate`, `task lint`, `tofu test` all green (full
  existing suite plus the new fixtures).

---

## Target 1 — `network` + `cluster` mode-aware; `create` IPAM/TGW levers; shared endpoint module; adopt preflight (L)

**Findings:**
- `components/aws/network/main.tf` — `module.vpc` hardcodes `cidr = var.vpc_cidr`
  (line 23), `enable_nat_gateway = true` (line 30); `module.vpc_endpoints` (lines
  56-151) always builds the S3 gateway + interface set inline; ELB role tags only
  (lines 41-47, `kubernetes.io/role/elb` / `role/internal-elb`). `variables.tf:22-26`
  default `vpc_cidr = "10.0.0.0/16"`. `outputs.tf` has no subnet AZs and no
  adopt-resolvable `vpc_cidr`.
- `components/aws/cluster/subnet_tags.tf:16-22` unconditionally stamps
  `kubernetes.io/cluster/<cluster>=shared` via `aws_ec2_tag` on every subnet — a
  cross-account participant cannot do this (owner-only), must gate off in adopt.
- `fleet/aws/cluster-stack/main.tf:71-117` wires `network` → `cluster` explicitly;
  `outputs.tf:40-43` returns only `vpc_id` from network.
- `terraform-aws-modules/vpc ~> 5.0` supports `ipv4_ipam_pool_id` +
  `ipv4_netmask_length` (leave `cidr` empty for IPAM allocation) and does **not**
  manage TGW attachments — those are separate `aws_ec2_transit_gateway_vpc_attachment`
  + `aws_route` resources. Verify the exact upstream module var names at
  implementation time (repo precedent for this check: `components/aws/cluster/karpenter.tf:13-21`).

**Approach:**
1. Extract the interface/gateway endpoint set from `network/main.tf` into a shared
   local module `components/aws/modules/eks-vpc-endpoints` (inputs: `vpc_id`,
   private subnet IDs, SG ID, `environment`, `enable_eks_interface_endpoint`, `tags`;
   the exact S3-gateway + ecr.api/ecr.dkr/sts/ssm/secretsmanager/eks-auth/
   aps-workspaces set that's in `network/main.tf` today). Both `network` (create
   mode) and the new `shared-network` component (Target 3) consume it — one
   foundation, no drift between the two.
2. `network`: add `network_mode` (`create`|`adopt`, default `create`,
   regex-validated). `create` inputs (all optional, defaults preserve today's
   behavior): keep `vpc_cidr`; add `ipam_pool_id` (default `""`),
   `ipam_netmask_length` (default `0`), `transit_gateway_id` (default `""`),
   `centralized_egress` (bool, default `false`). `adopt` inputs: `adopt_vpc_id`,
   `adopt_private_subnet_ids`, `adopt_public_subnet_ids` (defaults empty).
3. `create` mode: `module.vpc` as today when `ipam_pool_id == ""`; when set, pass
   `ipv4_ipam_pool_id` + `ipv4_netmask_length` and leave `cidr` empty. When
   `transit_gateway_id != ""`, add a TGW VPC attachment on the private subnets + a
   `10.0.0.0/8`-to-TGW route in the private route tables. When `centralized_egress`,
   set NAT gateway count to 0 and default-route `0.0.0.0/0` to the TGW instead of NAT.
4. `adopt` mode: skip `module.vpc` and the endpoint module (owner-run); resolve
   `vpc_id`/subnets/CIDR/AZs from the `adopt_*` inputs via read-only data sources.
   Outputs resolve identically in both modes; add `private_subnet_azs` /
   `public_subnet_azs` to `outputs.tf`.
5. **Consumer-side adopt preflight** — tofu `check` blocks + data-source
   preconditions that run at `plan` and fail there, not silently at cluster-Ready.
   Assert: each adopt subnet resolves and belongs to `adopt_vpc_id`; the private
   route tables carry an S3-gateway prefix-list route + a default egress route
   (via `data.aws_route_table`); AZ count meets `max_azs`. Document the hard limit
   explicitly in a comment: a participant cannot `DescribeVpcEndpoints` on foreign
   interface endpoints, so interface-endpoint completeness can't be hard-asserted
   here — it rides the owner's contract (Target 3's `check` blocks + README) plus DNS
   resolution at bootstrap. The gateway route and subnet-placement checks are the
   hard, observable-from-the-participant-side assertions.
6. `cluster`: add `stamp_subnet_tags` (bool, default `true`); gate
   `subnet_tags.tf`'s `aws_ec2_tag` resource on it (`false` in adopt). Comment why:
   a cross-account participant can't tag a foreign-owned subnet; the owner owns
   tagging.
7. `cluster-stack/{variables,main,outputs}.tf`: thread every new var through
   (defaults create/empty = unchanged behavior); pass
   `stamp_subnet_tags = var.network_mode == "create"` to the cluster module; add
   `private_subnet_ids`, `public_subnet_ids`, `private_subnet_azs` to `outputs.tf`
   (status plumbing Targets 4/5 depend on).
8. `live/_envcommon/aws/network.hcl` + the existing `live/.../network/terragrunt.hcl`
   files: no behavior change — defaults keep `create` mode + the raw literal CIDR.
   Do not populate `ram_principals` anywhere (N3 — activation is a separate,
   per-engagement action, not part of this target).
9. Preconditions in `network`: `adopt` requires non-empty `adopt_vpc_id` +
   `adopt_private_subnet_ids`; `centralized_egress` requires `transit_gateway_id`;
   TGW attach requires an IPAM-allocated CIDR (reject raw-literal `vpc_cidr` +
   `transit_gateway_id` together); `ipam_pool_id` and a non-default `vpc_cidr` are
   mutually exclusive.

**Acceptance:**
- `task fmt:check`, `task validate`, `task lint` all green.
- `task plan ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=network`
  on defaults resolves cleanly (create mode, raw literal CIDR, unchanged shape).
- `tofu test` (or targeted `plan` against fixture vars) covers: create default,
  create+IPAM (CIDR drawn from pool), create+TGW+centralized (0 NAT gateways + TGW
  route present), adopt (no VPC/endpoints created; outputs resolve from the supplied
  IDs).
- A plan with `network_mode=adopt` shows `aws_ec2_tag.subnet_cluster_ownership`
  absent from the plan.
- A fixture with an adopt subnet that doesn't belong to `adopt_vpc_id`, or a route
  table missing the S3-gateway route, fails at `plan` with a clear, specific error
  message (not a generic provider error).

---

## Target 2 — IP + auth hygiene on the cluster addon config (S) ✅

**Shipped (landing-zone#143, squash-merged).** Resolution of the one open evaluation:
`MINIMUM_IP_TARGET` was deliberately **not** set. AWS's prefix-mode guidance is explicit
that `WARM_IP_TARGET`/`MINIMUM_IP_TARGET` *override* `WARM_PREFIX_TARGET` and only earn
their keep when IPv4 space is scarce enough to ration. The create-mode /16 and
owner-sized adopt subnets aren't scarce, and one warm `/28` already covers the system
node group's steady pod set — so a floor would only turn `WARM_PREFIX_TARGET` into dead
config. Final vpc-cni `configuration_values`: `ENABLE_PREFIX_DELEGATION=true` (unchanged)
+ `WARM_PREFIX_TARGET=1`. The STS/Pod-Identity note is a comment on the
`eks-pod-identity-agent` addon block. No downstream-target impact.

**Depends on:** Target 1 (serialized after it in this repo; no functional dependency).

**Findings:** `components/aws/cluster/eks.tf:62-64` already sets
`ENABLE_PREFIX_DELEGATION=true` on the vpc-cni addon — this is already shipped, not a
gap. Missing: warm/min-IP floors that stop a fresh prefix-delegated node from either
hoarding IPs or starving under burst scheduling. The platform is on EKS Pod Identity
org-wide (not IRSA web-identity) and already has an `eks-auth` VPC endpoint
(`components/aws/network/main.tf:112-118`), so the global-STS-hang concern (from the
original pasted analysis) is largely moot for platform-managed identity — Pod
Identity doesn't use `AssumeRoleWithWebIdentity`. It only matters for tenant
workloads still on IRSA web-identity.

**Approach:**
1. In `cluster/eks.tf`'s vpc-cni `configuration_values`, add `WARM_PREFIX_TARGET=1`
   (the safe prefix-delegation default) and evaluate whether `MINIMUM_IP_TARGET`
   needs a floor for the system node shape (`system_node_instance_types` default);
   keep `ENABLE_PREFIX_DELEGATION=true` as-is. Comment: mode-independent, cheap
   insurance against IP exhaustion regardless of create/adopt.
2. Document (comment only, no code change) that platform-managed identity is
   Pod-Identity/`eks-auth`-endpoint-based so global STS is a non-issue there; tenant
   workloads still on IRSA web-identity that want the regional-STS guarantee set
   `AWS_STS_REGIONAL_ENDPOINTS=regional` at the pod level. Do not add a blanket
   cluster-wide mutation for this.

**Acceptance:** `task fmt:check`, `task validate`, `task lint` green;
`task plan ACCOUNT=workload-development REGION=us-west-2 ENVIRONMENT=development COMPONENT=cluster`
shows only the vpc-cni `configuration_values` change (an addon config update, not a
cluster or node-group replacement).

---

## Target 3 — `shared-network` owner component + RAM share + contract (L)

**Shipped.** New `components/aws/shared-network` (main/endpoints/tgw/subnet_tags/ram/ssm/
checks/variables/outputs/versions + smoke-test + README + tofu test suite), envcommon
`live/_envcommon/aws/shared-network.hcl`, and a new `network`-role account live tree
(`live/aws/network/{account.hcl, us-west-2/region.hcl,
us-west-2/{development,staging,production}/{env.hcl, shared-network/terragrunt.hcl}}`).
Resolution decisions worth recording:
- **IPAM CIDR sourcing = discover by tag, with an explicit override.** The org env sub-pool
  is not cross-account readable via SSM/state, so `shared-network` discovers it via
  `data.aws_vpc_ipam_pools` filtered on `tag:Name = org-ipam-<environment>` (the tag
  `org-networking` stamps) and `one()` (fails clearly on 0 or >1 match). `var.ipam_pool_id`
  (default `""`) is the explicit override / escape hatch. No terragrunt `dependency` block —
  a cross-account state read would be architecturally wrong and would trip the mock-outputs
  cross-check; discovery keeps the live leaf self-contained.
- **IPAM pin copied exactly from `network`** — `terraform_data.ipam_cidr_pin` (no `count`;
  IPAM is always on here), `input = data.aws_vpc_ipam_preview_next_cidr.this.cidr` under
  `lifecycle { ignore_changes = [input] }`; subnets + the endpoint-SG 443 CIDR carve off
  `.output`. Same known-after-apply-on-first-plan trade-off. Regression-covered by
  `ipam_pin_apply` + `ipam_pin_holds_day2`.
- **Role tags via the VPC module, not `aws_ec2_tag`.** `subnet_tags.tf` defines the role-tag
  locals (public `kubernetes.io/role/elb`, private `kubernetes.io/role/internal-elb`) + the
  "deliberately NO `kubernetes.io/cluster/*`" rationale; main.tf passes them as the module's
  `public/private_subnet_tags`. An `aws_ec2_tag` `for_each` over module-created subnet IDs
  can't resolve its keys at plan (IDs known-after-apply), so the module-tag path is the only
  plan-safe one for owner-built subnets — unlike the `cluster` component, which `aws_ec2_tag`s
  subnets it receives as *inputs* (plan-known).
- **RAM subnet associations use `count`, not `for_each`.** Subnet ARNs are known-after-apply,
  so `for_each` over them fails at plan; `count = length(shared_subnet_arns)` (list length is
  plan-known — one subnet per AZ per tier) with a `count.index` into the ARN list plans
  cleanly. Principal associations `for_each` over `consumer_account_ids` (plan-known var).
  Whole share gated on `length(consumer_account_ids) > 0`, mirroring org-networking.
- **Contract = tofu `check` blocks, gated hard by the test suite.** `checks.tf`:
  `endpoint_set_complete` (every required service key present in the endpoint module output),
  `consumers_declared` (non-empty `consumer_account_ids`), `role_tags_no_cluster_binding`.
  `check` blocks only *warn* at real plan/apply (non-blocking by design), but a failing check
  **fails a `tofu test` run** unless listed in `expect_failures` — so the two violation
  fixtures (`enable_vpc_endpoints=false`, empty consumers) gate the contract in CI.
- **mock_provider gotcha for RAM tests:** the RAM association resources validate
  `resource_arn` / `resource_share_arn` as ARNs at plan, so the test needs
  `mock_resource "aws_ram_resource_share"` and `mock_resource "aws_subnet"` with ARN-shaped
  `arn` defaults; the `aws_vpc_ipam_pools` discovery mock needs the FULL pool object shape
  (every attribute), not a partial `{ id = ... }`. Recorded for Target 3b's mock tests.
- **Committed placeholder account IDs:** `network` account.hcl uses `444444444444`; each
  env's `consumer_account_ids` points at the matching workload account's existing placeholder
  (dev `111111111111`, staging `222222222222`, production `333333333333`). All repeated-digit,
  clearly-fake; the README uses `111111111111`/`222222222222` as canonical placeholders.

> **Note from Target 3 (for Target 3b):** the `network`-role account scaffolding now exists —
> `live/aws/network/account.hcl`, `us-west-2/region.hcl`, and per-env `env.hcl` under
> `us-west-2/{development,staging,production}/`. Target 3b's `egress-network` live leaves drop
> straight into `live/aws/network/us-west-2/{env}/egress-network/terragrunt.hcl` (same account
> role — the central network team runs both the shared VPCs and the egress hub); no new
> account.hcl/region.hcl/env.hcl needed. Also: `shared-network` already ships the spoke-side
> of centralized egress (a `0.0.0.0/0` → TGW route on its private route tables under
> `centralized_egress=true`, in `tgw.tf`); Target 3b builds the *receiving* end (the central
> egress VPC + the static `0.0.0.0/0` TGW route in the TGW default route table) — the two
> compose but neither creates the other's resources, exactly as the plan scoped.

**Depends on:** Target 1 (consumes the extracted shared endpoint module).

> **Note from Target 1 (build discoveries that change this target):**
> - **Module path.** The shared endpoint module landed at
>   `modules/aws/eks-vpc-endpoints`, NOT `components/aws/modules/eks-vpc-endpoints`.
>   The repo's shared-module convention is `modules/aws/{name}` (workload-identity,
>   platform-app), and `task validate` + CI's validate matrix key on the first three
>   path segments (`git ls-files | awk '{print $1"/"$2"/"$3}'`) — a module under
>   `components/aws/modules/…` would emit a broken `components/aws/modules` validate
>   root. Reference `../../../modules/aws/eks-vpc-endpoints` from `shared-network`.
> - **Module interface.** Inputs are `vpc_id`, `private_subnet_ids`, `route_table_ids`
>   (the S3 gateway endpoint needs the route-table IDs — this was implicit in the
>   original input list), `security_group_id` (the caller owns the SG that scopes 443
>   to its VPC CIDR — the module does NOT create it), `environment`,
>   `enable_eks_interface_endpoint`, `tags`. Output: `endpoints` (the full endpoint
>   map). `shared-network` builds its own endpoint SG + passes its ID in, exactly as
>   `network` does.
> - **IPAM CIDR carving — DO NOT mirror the raw pattern as originally shipped.** An
>   IPAM-drawn VPC CIDR is unknown at plan, so subnets can't be `cidrsubnet()`'d off
>   the VPC output directly. `network`'s create-mode path used
>   `data.aws_vpc_ipam_preview_next_cidr` (args `ipam_pool_id` + `netmask_length`,
>   output `cidr`) to get the next-allocatable block at plan and carved subnets off
>   that raw preview — **a second independent review found this has a confirmed
>   upstream day-2 replan bug** (terraform-aws-modules/vpc#980): the preview
>   re-evaluates on every plan, so once the VPC actually allocates the previewed
>   block, the next plan previews a *different* CIDR and every subnet plans as a
>   destructive replacement that can't even apply. Target 1-fix (runs before this
>   target) pins the preview in state via a `terraform_data`/
>   `aws_vpc_ipam_pool_cidr_allocation` resource with `ignore_changes`. **Copy
>   whichever pinning approach Target 1-fix actually ships in `network`, not the raw
>   `data.aws_vpc_ipam_preview_next_cidr` read** — read `network/main.tf` fresh at
>   implementation time to get the corrected pattern, don't trust this description of
>   the original (buggy) shape. The VPC still allocates via `use_ipam_pool = true` +
>   `ipv4_ipam_pool_id` + `ipv4_netmask_length` + `cidr = null` (verified upstream var
>   names) — only the subnet-carving base changes. The endpoint SG should scope 443 to
>   the pinned base CIDR, not the module's computed `vpc_cidr_block` (unknown at plan
>   under IPAM).
> - **Contract the consumer preflight asserts (Target 1 side, for the README to match).**
>   The adopt preflight hard-fails at `plan` on: each adopt subnet resolving into
>   `adopt_vpc_id`; every adopted private route table carrying a route matched by *exact*
>   prefix-list ID to the region's S3 gateway managed prefix list
>   (`com.amazonaws.<region>.s3`) AND a `0.0.0.0/0` default egress route with a *live*
>   target (a NAT gateway or the TGW, not a blackhole); adopted private subnets spanning ≥
>   `max_azs` zones. Interface-endpoint completeness is NOT assertable from the participant
>   side (a participant can't `DescribeVpcEndpoints` on foreign endpoints) —
>   `shared-network`'s own `check` blocks + README carry that half of the contract.

> **Note from Target 1-fix (shipped — the concrete shapes Target 3 builds on):**
> - **IPAM pin — copy this exactly** (per the DO-NOT-mirror-the-raw-preview note above).
>   The carving base is pinned with a `terraform_data` resource whose `input` is
>   `data.aws_vpc_ipam_preview_next_cidr.this[0].cidr` under
>   `lifecycle { ignore_changes = [input] }` — resource name `terraform_data.ipam_cidr_pin`,
>   `count = local.ipam_enabled ? 1 : 0`. `local.subnet_base_cidr` and the endpoint SG's
>   443 `cidr_blocks` carve off `terraform_data.ipam_cidr_pin[0].output`, never the data
>   source directly. The `aws_vpc_ipam_pool_cidr_allocation` alternative was NOT needed —
>   the `terraform_data` pin integrates cleanly with the upstream module's `use_ipam_pool`
>   inputs. One trade-off `shared-network` will share: `terraform_data.output` is
>   `(known after apply)` on the first plan, so subnet + endpoint-SG CIDRs read as
>   known-after-apply until the first apply — inherent to any state-pin, and the correct
>   trade for day-2 stability. Regression-covered by `ipam_pin_apply` +
>   `ipam_pin_holds_on_day2` in `components/aws/network/tests/network.tftest.hcl`.
> - **Write the README to the *tightened* preflight** (exact S3 prefix-list ID + live
>   default-egress target, per the updated Contract bullet above), not the looser
>   `destination_prefix_list_id != ""` / destination-only shape the raw Target 1 shipped.
> - **`private_route_table_ids` is not 1:1 with subnets** (create mode collapses to one
>   shared table under `nat_gateways = 1`; adopt resolves one table per subnet, repeating
>   when subnets share a table). Owner-side or status plumbing must de-duplicate.
> - **AZ IDs, not names, for cross-account status.** `network` now also outputs
>   `private_subnet_az_ids` / `public_subnet_az_ids` (AZ IDs like `usw2-az1`, via
>   `data.aws_subnet.*.availability_zone_id` in adopt and `aws_availability_zones.zone_ids`
>   in create), and `fleet/aws/cluster-stack` re-exports both. Target 5 threads
>   cluster-stack's `private_subnet_az_ids` into `status.subnetAzIds`; the name-based
>   `private_subnet_azs` stays for same-account readability but is NOT the cross-account
>   field.

**Account topology (already worked out — build to this, don't re-derive it):**
Three account roles, two RAM hops.
- **Management account** — `org-networking` (existing, unchanged by this target)
  owns the TGW + IPAM (top pool `10.0.0.0/8` + env sub-pools) and RAM-shares to
  `ram_principals`. Activation for cross-account: the network-owner account ID goes
  into `ram_principals` at
  `live/aws/management/us-west-2/org/org-networking/terragrunt.hcl` (stays `[]` in
  the committed tree per N3; any committed *examples* use placeholder account IDs
  `111111111111`/`222222222222`, never real ones). Hop 1: org-networking →
  **IPAM pool + TGW** → network-owner account.
- **Network-owner account** (new account role, `network`) — runs `shared-network`
  (this target): draws a VPC CIDR from the RAM-shared org IPAM env sub-pool, builds
  the full private endpoint set (via the Target 1 shared module), owner-run egress
  (NAT or TGW attach), the cluster-agnostic role-tag convention, and RAM-shares its
  subnets onward to the consuming workload account. Hop 2: shared-network →
  **subnets** → workload account.
- **Workload account** — runs `network` in `adopt` mode (Target 1) referencing the
  shared VPC + subnet IDs, plus `cluster` with `stamp_subnet_tags=false`.

Chosen shape: a single `network`-role account holding per-environment VPCs
(`live/aws/network/us-west-2/{development,staging,production}/shared-network/`),
each RAM-sharing to its matching `workload-{env}` account — mirrors how a real
central network team runs one account. (Account-per-environment is the
stricter-isolation alternative; that's a live-tree layout choice at activation time,
not a `shared-network` component change — no action needed here.)

**Findings:**
- `components/aws/org-networking/ipam.tf:46-90` already builds env sub-pools and
  RAM-shares them when `ram_principals` is non-empty; `main.tf:81-88` publishes the
  pool ID to the management account's own SSM (not cross-account readable — so the
  pool ID must be a `shared-network` input, or discovered via
  `data.aws_vpc_ipam_pools` filtered by tag).
- `components/aws/network/main.tf:41-47` is the role-tag convention to reuse
  (`kubernetes.io/role/elb`, `role/internal-elb`); `components/aws/cluster/subnet_tags.tf`
  is the per-cluster ownership tag `shared-network` must deliberately NOT emit.
- Component conventions to mirror (see any existing `components/aws/*`): `versions.tf`,
  `smoke-test.sh`, the envcommon interface vars (declare `region` even if unused,
  tagged `# tflint-ignore: terraform_unused_declarations` per this repo's CLAUDE.md),
  the `environment` format-contract validation regex.

**Approach — files to create:**
- `components/aws/shared-network/main.tf` — VPC with an IPAM-drawn CIDR
  (`ipv4_ipam_pool_id` + `ipv4_netmask_length`), public/private/intra subnets across
  `max_azs`, owner-run egress (NAT gateways when `centralized_egress=false`; TGW
  attachment + default route when `true`).
- `components/aws/shared-network/endpoints.tf` — consumes
  `components/aws/modules/eks-vpc-endpoints` (Target 1): the full private endpoint
  set, private DNS enabled, `enable_eks_interface_endpoint` gated the same way
  `network` gates it.
- `components/aws/shared-network/subnet_tags.tf` — owner stamps
  `kubernetes.io/role/elb=1` (public) + `kubernetes.io/role/internal-elb=1`
  (private) only; explicitly **no** `kubernetes.io/cluster/*` tag (the documented
  cluster-agnostic contract — cross-account consumers select subnets by explicit ID
  regardless, since RAM hides these tags from participants anyway; the tags exist
  for same-account participants and as the owner's own authoritative convention).
- `components/aws/shared-network/ram.tf` — `aws_ram_resource_share` +
  `aws_ram_resource_association` per shared subnet (private always; public when
  `share_public_subnets`) + `aws_ram_principal_association` per
  `consumer_account_ids`. `allow_external_principals = false`.
- `components/aws/shared-network/ssm.tf` — publish subnet IDs/AZs/`vpc_id`/
  `ram_share_arn` to the owner account's own SSM under `/platform/<env>/shared-network/*`
  (for the owner's own automation; not cross-account readable).
- `components/aws/shared-network/checks.tf` — owner-side contract assertion
  (tofu `check` blocks): the endpoint set is complete (every required service
  present), role tags are stamped on every shared subnet, `consumer_account_ids` is
  non-empty. Fails `plan` if the contract the consumer's Target-1 preflight relies on
  is incomplete.
- `components/aws/shared-network/{variables,outputs,versions}.tf`, `smoke-test.sh`.
- `components/aws/shared-network/README.md` — **the contract** Target 1's consumer
  preflight asserts against: which endpoints exist, which route table entries exist
  (S3 gateway route + default egress route), the role-tag convention, the RAM-share
  scope. This is the operational hand-off document between owner and consumer.
  Additional required sections (from the second review pass): (a) **explicit route-
  table associations mandatory** — the consumer preflight's `data.aws_route_table`
  lookup only matches subnets with an explicit route-table association, not one
  riding the VPC's implicit main route table; state this as a hard requirement (this
  component itself, built on `terraform-aws-modules/vpc`, already complies — the
  README is guidance for anyone hand-rolling a different owner network against this
  same contract); (b) **owner-side activation and teardown prerequisites** — RAM
  requires org-wide resource sharing enabled in AWS Organizations before
  `allow_external_principals = false` shares will resolve for principals outside the
  owner's own account tree, and there's currently no automated unshare/teardown path
  — document the manual sequence (drain consumer-side ENIs from shared subnets
  before revoking the RAM association, or the unshare fails/orphans state) since
  nothing in this target automates it.
- `live/_envcommon/aws/shared-network.hcl` — envcommon interface (`team = "platform"`,
  source path, dependency wiring).
- `live/aws/network/us-west-2/{development,staging,production}/shared-network/terragrunt.hcl`
  — example instantiation with placeholder `consumer_account_ids` and a
  `dependency`/data-source read of the RAM-shared IPAM pool.

**Acceptance:**
- `task fmt:check`, `task validate`, `task lint` all green.
- `tofu test` (or `task plan` against fixture vars) covers: NAT-egress owner VPC
  (endpoints + role tags + RAM share all planned), TGW-centralized-egress owner VPC
  (0 NAT gateways, TGW route present), and a contract-violation fixture (drop one
  required endpoint, or empty `consumer_account_ids`) that fails the `check` block at
  `plan`.
- A plan shows the RAM subnet share targeting `consumer_account_ids` and zero
  `kubernetes.io/cluster/*` tags on any subnet in the plan.

---

## Target 3b — `egress-network` owner component: central-egress VPC + TGW static default route (M)

**Depends on:** Target 1 (network var-naming conventions; no other coupling — this
is a standalone component, independent of Target 3's `shared-network`).

**Context — why this exists.** A second independent review pass found that Target
1's `centralized_egress` lever (route a `create`-mode cluster's default egress
through the TGW instead of local NAT) has no owner-side receiving end anywhere in
the original plan: no central egress VPC, and critically, TGW default-route-table
`propagation` only propagates *attachment CIDRs* — it never creates the static
`0.0.0.0/0` route a spoke needs to actually reach the internet through the TGW.
Flipping the lever as originally scoped would blackhole egress. Decision (greenfield
— nothing is deployed, no live-risk argument for leaving it inert; this campaign's
N2 precedent already favors building complete over deferred): build the small
owner-side piece now rather than ship a documented-but-non-functional knob.

**Findings:**
- `components/aws/org-networking` (existing, unchanged by this target) owns the TGW
  and sets `auto_accept_shared_attachments = "enable"`, so a cross-account TGW
  attachment from this new component's account needs no manual accept step.
- Nothing in the repo creates an `aws_ec2_transit_gateway_route` (a *static* route,
  distinct from the automatic propagation `org-networking`'s
  `tgw_default_route_table_association`/`propagation = true` already provides for
  attachment CIDRs). This is the missing piece.
- This is deliberately a **separate** component from `shared-network` (Target 3):
  `shared-network` serves the `adopt` topology (workload accounts place cluster ENIs
  directly in owner-run subnets); `egress-network` serves the `create` +
  `centralized_egress` topology (workload accounts keep their own VPC via `network`
  create mode, but route egress through this hub). Different consumer, different
  account role — don't merge them into one component.

**Approach — files to create:**
- `components/aws/egress-network/main.tf` — a small VPC (its own dedicated CIDR
  block — this is infra, not workload address space, so it does not need to draw
  from the workload IPAM pools; a `/24`-class block per environment is plenty), NAT
  gateway(s) in public subnets, a TGW attachment on the NAT-facing subnets.
- `components/aws/egress-network/tgw_route.tf` — the `aws_ec2_transit_gateway_route`
  static `0.0.0.0/0` route in the TGW's default route table, targeting this
  component's TGW attachment. This is the one resource that actually makes
  `centralized_egress=true` functional for every spoke attached to the same TGW.
- `components/aws/egress-network/{variables,outputs,versions}.tf`, `smoke-test.sh`,
  `README.md` (document: one egress-network instantiation per TGW is correct — a
  second one competing for the same static default route is a footgun, call it out
  explicitly).
- `live/_envcommon/aws/egress-network.hcl` +
  `live/aws/network/us-west-2/{development,staging,production}/egress-network/terragrunt.hcl`
  (or a single non-per-env instantiation if one shared egress point across
  environments is the intended shape — decide based on whether `org-networking`'s
  per-env IPAM sub-pools imply per-env egress too; default to per-env to match the
  rest of this campaign's account topology unless a strong reason emerges to share
  one egress point across environments).

**Acceptance:**
- `task fmt:check`, `task validate`, `task lint` all green.
- `tofu test` (or `task plan` against fixture vars) shows: the egress VPC + NAT +
  TGW attachment planning cleanly, and the static `0.0.0.0/0` TGW route targeting
  this attachment.
- A fixture plan for `network` (Target 1) with `centralized_egress=true` +
  `transit_gateway_id` pointing at the same TGW this component attaches to shows a
  complete, coherent path on paper: spoke default route → TGW → this component's
  static route → NAT → internet. (Full live validation isn't possible — nothing is
  deployed — but the plan-time story should be traceable end to end across both
  components' outputs/inputs.)

---

## Target 4 — cluster-bootstrap publishes `network_mode` + adopt subnet IDs (public + private) (M)

**Depends on:** Target 1.

> **Note (second review pass):** the original scope here published only
> `private_subnet_ids`. That's public-subnet-blind — an internet-facing ALB/NLB
> needs public subnets, and Target 6's Kyverno injection would silently mis-wire any
> internet-facing Ingress/Service in an adopt cluster. Publish both.

**Findings:** `components/aws/cluster-bootstrap/bootstrap.tf:341-405` writes the
`in-cluster` ArgoCD cluster Secret (labels: `environment`, `cluster_name`, `vpc_id`,
`region`; annotations carry ARN/endpoint values). It receives `vpc_id` from the
composition but no subnet IDs or mode today. It uses `kubernetes_secret_v1`; no
ConfigMap exists in this component yet. Two downstream consumers need this data in
two different shapes: the eks-gitops ApplicationSet generator can only read cluster
Secret labels/annotations (→ needs an annotation), and Kyverno (Target 6, a different
repo) reads cluster-local resources at admission time (→ needs a ConfigMap). One
source of truth, two purpose-fit sinks.

**Approach:**
1. `fleet/aws/cluster-bootstrap` + `components/aws/cluster-bootstrap` variables: add
   `network_mode` (default `create`), `private_subnet_ids` (list, default `[]`),
   AND `public_subnet_ids` (list, default `[]`).
2. `argocd_cluster` Secret: add label `network_mode` (always set — so the eks-gitops
   generator can key on it unconditionally) and, when `network_mode == "adopt"`, two
   annotations: `network/private-subnet-ids` and `network/public-subnet-ids`
   (comma-joined subnet IDs each — annotations, not labels, since comma-separated
   lists exceed label-value character-class rules). Both absent/empty when in
   `create` mode.
3. New `kubernetes_config_map_v1` in `kube-system` (name: `network-config`), written
   in **both** modes, with `data.network_mode` + `data.private_subnet_ids` +
   `data.public_subnet_ids` (CSVs, empty strings in create mode) — this is the
   Kyverno context source Target 6 reads, and Target 6's mutation needs both to be
   scheme-aware (internal LB → private subnets, internet-facing → public). Always-
   present ConfigMap avoids Kyverno "context source missing" failures on create-mode
   clusters.
4. Defaults (`create`/empty) leave today's Secret shape unchanged aside from the new
   always-present `network_mode=create` label; no consumer breaks in create mode
   (empty subnet CSVs + `network_mode=create` on the new ConfigMap).

**Acceptance:** `task fmt:check`, `task validate`, `task lint` green; a render/plan
with `network_mode=create` shows the Secret gaining only the `network_mode=create`
label, plus a `network-config` ConfigMap with empty subnet-ID data for both CSVs; a
render/plan with `network_mode=adopt` shows both populated
`network/private-subnet-ids` + `network/public-subnet-ids` Secret annotations and
both populated ConfigMap CSVs.
