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
| 2 | IP + auth hygiene on cluster addon config | ⬜ |
| 3 | `shared-network` owner component + RAM share + contract | ⬜ |
| 4 | cluster-bootstrap publishes network_mode + adopt subnet IDs | ⬜ |

Run these **serialized, in order** (1 → 2 → 3 → 4) — never two agents in this repo
concurrently. Every target ends in a PR (never a direct push to `main`, even though
this repo's branch protection allows an admin bypass), CI green (poll `gh pr checks`
synchronously in the foreground — no backgrounded `--watch`, no ending your turn to
wait on it), then squash-merge.

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

## Target 2 — IP + auth hygiene on the cluster addon config (S)

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
> - **IPAM CIDR carving.** An IPAM-drawn VPC CIDR is unknown at plan, so subnets can't
>   be `cidrsubnet()`'d off the VPC output. The create-mode `network` pattern uses
>   `data.aws_vpc_ipam_preview_next_cidr` (args `ipam_pool_id` + `netmask_length`,
>   output `cidr`) to get the next-allocatable block at plan and carves subnets off
>   that, while the VPC allocates via `use_ipam_pool = true` + `ipv4_ipam_pool_id` +
>   `ipv4_netmask_length` + `cidr = null` (verified upstream var names). Mirror this in
>   `shared-network`. The endpoint SG should scope 443 to the previewed base CIDR
>   (`local.subnet_base_cidr`), not the module's computed `vpc_cidr_block` (unknown at
>   plan under IPAM).
> - **Contract the consumer preflight asserts (Target 1 side, for the README to match).**
>   Target 1's adopt preflight hard-fails at `plan` on: each adopt subnet resolving into
>   `adopt_vpc_id`; every adopted private route table carrying an S3-gateway prefix-list
>   route (`destination_prefix_list_id != ""`) AND a `0.0.0.0/0` default egress route;
>   adopted private subnets spanning ≥ `max_azs` zones. Interface-endpoint completeness
>   is NOT assertable from the participant side (a participant can't
>   `DescribeVpcEndpoints` on foreign endpoints) — `shared-network`'s own `check` blocks
>   + README carry that half of the contract.

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

## Target 4 — cluster-bootstrap publishes `network_mode` + adopt subnet IDs (M)

**Depends on:** Target 1.

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
   `network_mode` (default `create`) and `private_subnet_ids` (list, default `[]`).
2. `argocd_cluster` Secret: add label `network_mode` (always set — so the eks-gitops
   generator can key on it unconditionally) and, when `network_mode == "adopt"`, an
   annotation `network/private-subnet-ids` = comma-joined subnet IDs (annotation, not
   label — comma-separated lists exceed label-value character-class rules). Absent/
   empty when in `create` mode.
3. New `kubernetes_config_map_v1` in `kube-system` (name: `network-config`), written
   in **both** modes, with `data.network_mode` + `data.private_subnet_ids` (CSV,
   empty string in create mode) — this is the Kyverno context source Target 6 reads.
   Always-present ConfigMap avoids Kyverno "context source missing" failures on
   create-mode clusters.
4. Defaults (`create`/empty) leave today's Secret shape unchanged aside from the new
   always-present `network_mode=create` label; no consumer breaks in create mode
   (empty subnet CSV + `network_mode=create` on the new ConfigMap).

**Acceptance:** `task fmt:check`, `task validate`, `task lint` green; a render/plan
with `network_mode=create` shows the Secret gaining only the `network_mode=create`
label, plus a `network-config` ConfigMap with empty subnet-ID data; a render/plan
with `network_mode=adopt` shows the populated `network/private-subnet-ids` Secret
annotation and the populated ConfigMap CSV.
