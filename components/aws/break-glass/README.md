# break-glass

An emergency administrator role for one workload account. It is for an incident where the
account's own IAM is misconfigured or compromised, so a principal inside the account cannot
be trusted to fix it. The role lets a principal in another account act as administrator, and
it announces every use. [RB-003](../../../docs/runbooks.md#rb-003-break-glass-access) is the
procedure for using it.

## What it builds

- **The role**, `<environment>-break-glass`, with `AdministratorAccess`. A session lasts at
  most `max_session_duration` seconds (default 3600). The trust admits only the root of each
  account in `trusted_account_ids`, and only with MFA (`aws:MultiFactorAuthPresent`).
- **A permissions boundary**, on unless `enable_permissions_boundary = false`. It allows
  everything, then denies the IAM writes a session could use to outlast the incident:
  creating or deleting users, roles and policies, creating access keys, attaching or inlining
  a policy on a role or user, detaching or deleting a role's policy, publishing a policy
  version, rewriting a trust policy, and replacing or removing a boundary. It also denies
  `sts:AssumeRole` and every `organizations:*` action.
- **Detection.** The `<environment>-break-glass-detection` EventBridge rule matches
  CloudTrail's `AssumeRole` record for the role. It publishes the record to the
  `<environment>-break-glass-alert` SNS topic, which is encrypted with its own CMK and emails
  each address in `notification_emails`.
- **An alarm on delivery.** `<environment>-break-glass-delivery-failed` fires when the rule
  fails to deliver to the topic (its `FailedInvocations`). It publishes through CloudWatch,
  not the EventBridge path it watches.
- **The role's ARN in SSM**, at `/<environment>/break-glass/role-arn`.

## Why another account

The trust names other accounts on purpose. Break-glass is for the case where this account's
IAM cannot be trusted, and a principal inside the account depends on that same IAM. So the
component refuses an empty `trusted_account_ids`, which would be a role nobody can assume. It
also refuses `123456789012`, the placeholder id for the management account. A role trusting
it is assumable by nobody, yet reads as configured.

## Deploy

An account has this role only once its leaf
(`live/aws/workload-<env>/us-east-1/<env>/break-glass`) names a trusted account and is
applied. A leaf whose `trusted_account_ids` is empty is refused, and creates no role. The
account meant to hold the emergency operators is the management account, so a leaf can name
it only once that account exists. To stand the role up in an account:

1. Set `trusted_account_ids` in the leaf to the management account's id.
2. Set `notification_emails` to the people who must hear about every use. With none set, the
   alert reaches nobody.
3. Apply the leaf. Each address then receives a subscription confirmation from SNS, and the
   alert reaches it only once confirmed.
4. Follow RB-003 once from the management account, MFA included, and check that the alert
   arrives.

## Testing

`tofu test` (`tests/break-glass.tftest.hcl`) runs against a mocked provider. It asserts that:

- the trust requires MFA and names only the trusted accounts' roots, never a wildcard;
- the boundary denies the self-escalation verbs and `organizations:*`, is attached to the
  role, and the session is bounded;
- the alert topic is encrypted and grants its publishers;
- the rule's delivery failures are alarmed;
- an empty trust list and the management-account placeholder are both refused.
