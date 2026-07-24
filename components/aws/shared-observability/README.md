# shared-observability

The fleet-wide destination for **alarm delivery**. A shared-services account runs one set of
severity-routed SNS topics (`critical` / `warning` / `info`) that every workload account's
CloudWatch alarms publish to, so a fleet-wide on-call watches one topic set instead of one per
cluster.

## The split

Alarm *definitions* stay local to the resources they watch — an alarm references local resource
ARNs and metric dimensions, so hoisting the definition would hoist the ARNs. Only the
*destination* centralizes:

```
workload account                         shared-services account
  observability (adopt mode)   ──publish──▶  shared-observability
  CloudWatch alarms                          critical / warning / info topics
  (definitions stay here)                    (the fleet's one destination)
```

A workload cluster runs `observability` in **adopt mode**: it builds no topics of its own and
points the same alarms at these central topics (`sns_topic_arns` re-exports them, so a consumer
wires against one interface either way). In **create mode** — the default, and how a standalone
cluster runs — `observability` builds its own topics locally.

## Cross-account publish is by org membership

Adding a workload account needs **no edit here** — the maintenance win, and the grant that
otherwise breaks alarm delivery silently as the fleet grows. Both surfaces are scoped to the
organization:

1. **Topic policies** admit `SNS:Publish` from the CloudWatch service principal.
2. **The topics' CMK** admits the `kms:GenerateDataKey*` a publish performs.

Both ride an `aws:SourceOrgID` condition equal to `organization_id`. The key detail: a *service*
principal (`cloudwatch.amazonaws.com`) acting cross-account populates `aws:SourceOrgID` — the org
of the resource it acts for — not `aws:PrincipalOrgID`, which scopes IAM-principal callers.

## Fleet-wide, not per-environment

Unlike a per-cluster estate, this is one instance for the whole fleet — one on-call topic set.
It runs in the shared-services account, and the workload AMP/dashboard estate (per-environment
metric stores, one central Grafana) is a separate concern (see
[central-observability](../../../../.plans/central-observability.md) O3).

## Deploy

1. Provision the shared-services account and replace the `777777777777` placeholder in
   `live/aws/shared-services/account.hcl`.
2. Set the real `o-xxxxxxxxxx` organization id in
   `live/_envcommon/aws/shared-observability.hcl`.
3. Apply this component, and wire the on-call address(es) into its leaf.
4. Point each workload cluster's `observability` at it: `observability_mode = "adopt"` with
   `adopt_topic_arns` set to this component's `sns_topic_arns`.

Until the shared-services account exists, workload `observability` runs in create mode — its own
local topics, the shape before central alarm delivery is stood up.
