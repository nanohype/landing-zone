# shared-dns

The owner side of private DNS across accounts. A network-owner account runs this component
once per environment. It holds the private hosted zones and a Route 53 Profile that carries
them, and it RAM-shares the Profile to the workload accounts that adopt it.

## Where it sits

```
network-owner account                                workload account
  shared-network  ──seed VPC──▶  shared-dns  ──RAM──▶  private-dns (adopt mode)
                                 (zones + Profile)      associates the Profile
                                                        with its cluster VPC
```

A consumer associates the Profile with its VPC, and every zone the Profile carries resolves
there. The owner attaches a zone once; no zone is associated VPC by VPC.

A workload environment in this tree runs `private-dns` in `create` mode with its own zone,
because a workload leaf may not depend on another account's state (the installability rule in
`CLAUDE.md`). So it does not consume this Profile, and it comes up without the network
account. The adopt wiring is the worked example under `live/aws/reference-adopt/`.

## The contract

This is the hand-off a consumer depends on and cannot check from its side: it sees only its
own Profile association succeed. Anyone standing up an owner without this component has to
meet the same terms.

- **At least one zone, attached to the Profile.** A Profile with no zones shares nothing, so
  `private_zones` refuses an empty list.
- **Each zone seeded with a VPC in the owner account.** Route 53 creates a private hosted
  zone only with a same-account VPC association. The seed is the network account's
  `shared-network` VPC. Resolution elsewhere rides the Profile, not the seed. The zone
  resource ignores changes to its VPC associations, because those the Profile makes on
  consumer VPCs are not this resource's to manage.
- **A RAM share inside the organization.** The share sets `allow_external_principals = false`
  and grants the default, read-only RAM permission. A consumer can associate the Profile with
  its VPCs. It cannot change the Profile or attach resources of its own to it.
- **At least one consumer.** With `consumer_account_ids` empty, no share is built. The
  `consumers_declared` check then warns at plan and apply, and the `tofu test` suite holds it
  as a failure.
- **The Profile's id and the share's ARN in SSM**, at `/platform/<env>/shared-dns/profile-id`
  and `/platform/<env>/shared-dns/ram-share-arn`. They serve consumers that read through SSM
  rather than a terragrunt dependency, as the `shared-network` parameters do.

## Consuming the Profile (workload account)

Run `private-dns` in `adopt` mode against this component's `profile_id` output, as
`live/aws/reference-adopt/us-east-1/development/private-dns/terragrunt.hcl` does:

```hcl
# workload account, private-dns leaf
inputs = {
  dns_mode   = "adopt"
  profile_id = dependency.shared_dns.outputs.profile_id
}
```

The association is inert unless the consumer VPC has DNS resolution enabled, and the
`private-dns` preflight asserts that at plan.

## Activation prerequisites

- **Enable resource sharing with AWS Organizations** (`aws ram enable-sharing-with-aws-organizations`,
  once per organization), as for `shared-network`. Without it, a share that admits no
  external principals does not resolve for the other accounts in the organization.
- **Name the real consumers.** `111111111111` in a leaf's `consumer_account_ids` is a
  placeholder. Set it to the real workload account, the same one the sibling `shared-network`
  leaf shares to. Every id must be a member of the organization.

## Hosted zone tags

Route 53 accepts at most 10 tags in the one call that sets a zone's tags, and the root
default tags already exceed that. The zones are therefore created through a provider with no
default tags (`route53-tags.tf`), carrying an explicit set instead. A zone given one tag too
many fails its precondition at plan.

## Inputs (selected)

| Input | Default | Notes |
|-------|---------|-------|
| `seed_vpc_id` | — | an owner-account VPC; envcommon wires the sibling `shared-network` VPC |
| `private_zones` | — | at least one zone name |
| `consumer_account_ids` | `[]` | workload accounts to RAM-share the Profile to |

## Testing

`tofu test` (`tests/shared-dns.tftest.hcl`) runs against a mocked provider. It covers zones,
Profile, attachments and share for one consumer; zone counts tracking the list; the share
dropping out and the check firing with no consumers; a malformed seed VPC, an empty zone
list or a malformed consumer id being refused; and the zone tag limit. After an apply,
`smoke-test.sh` checks the live Profile, its attached zones and the share.
