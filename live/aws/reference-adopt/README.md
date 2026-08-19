# reference-adopt — the worked adopt-mode wiring

This tree is documentation that CI renders. It is not a deployable environment, and
nothing in it should be applied as-is.

## What it shows

The consumer side of the cross-account shared-network topology: a spoke account
whose `network` and `private-dns` components run in **adopt** mode, consuming
resources that owner components in the network account create and RAM-share, rather
than creating their own.

| leaf | mode | adopts | from |
| --- | --- | --- | --- |
| `network` | `network_mode = "adopt"` | VPC + subnets | `live/aws/network/us-west-2/development/shared-network` |
| `private-dns` | `dns_mode = "adopt"` | a Route53 Profile | `live/aws/network/us-west-2/development/shared-dns` |

Both dependency `config_path`s reach out of this account directory into the network
account's tree, which is the whole point — that reach is what adopt mode *is*. It is
also why these leaves live here instead of in a workload environment.

## Why it is not in workload-development

It used to be, and that made the default environment un-installable.

A terragrunt `dependency` block is resolved while the unit's config is parsed —
before any tofu process starts, and before any `TF_VAR_*` could reach one. Both
leaves allow mocks for `validate` and `plan` only, so with the owner's state absent,
`terragrunt init` and `terragrunt apply` both hard-fail on an unresolvable dependency
output. No override rescues it: `network_mode` is set in the leaf's `inputs`, and the
`adopt_*` values *are* the dependency outputs.

That failure had no way to surface. The evaluate job renders against mocks by design,
and the plan job green-skips whenever `AWS_ROLE_ARN` is unset, so a leaf whose apply
path cannot resolve stayed green indefinitely. `scripts/check-account-local-deps.py`
now encodes the rule that was previously only a convention: a leaf under
`live/aws/workload-*/` may not depend on a unit outside its own account directory.
This tree is not `workload-*`, so the example keeps working.

## Standing it up for real

The owner side has to exist first, and today it does not — end to end:

1. `live/aws/management/us-west-2/org/org-networking` mints the IPAM pools, but its
   committed leaf sets `ram_principals = []`, which gates off all three RAM shares.
   Without principals, nothing is shared.
2. `components/aws/shared-network` discovers its pool by tag and has **no
   literal-CIDR path** — `cidr = null`, `use_ipam_pool = true`, unconditional, with no
   `cidr` variable at all. Its postcondition fails with "matched 0 pools, expected
   exactly 1" until step 1 shares one.
3. Only then can a consumer adopt.

So a single-account bootstrap cannot use this shape. That is why `create` is the
default in every workload environment, and why the day-0 path is create-mode only.

## Copying it

Change the account id in `account.hcl`, point the two `config_path`s at the owner
environment you actually run, and set the owner's `consumer_account_ids` to include
your spoke. The dependency blocks and `inputs` copy verbatim — a consuming account
never hand-copies subnet IDs or a Profile ID.
