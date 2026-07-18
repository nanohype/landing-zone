# Unit tests for break-glass — the emergency-admin escape hatch. This role grants
# AdministratorAccess, so the ONLY things standing between a legitimate incident and
# a full account takeover are the guardrails on how it can be assumed and what it is
# forbidden from doing. Those guardrails are the crown-jewel invariants under test:
#
#   1. MFA gate            — the assume-role trust MUST require
#                            aws:MultiFactorAuthPresent=true. Drop it and a leaked
#                            long-lived credential from a trusted account assumes
#                            admin with no second factor.
#   2. Trust scoping       — the trust Principal.AWS is the root ARNs of the
#                            trusted accounts ONLY, never "*". A wildcard principal
#                            (behind MFA or not) lets any principal in any account
#                            assume admin.
#   3. Self-escalation Deny — the permissions boundary's DenyIAMModifications Sid
#                            must Deny the IAM write verbs AND organizations:* with
#                            Effect=Deny. An explicit Deny is the ceiling: even the
#                            emergency admin cannot mint/alter identities or re-org
#                            the account to persist access after the glass is broken.
#   4. Boundary attached   — the Deny above is inert unless the boundary policy is
#                            actually bound to the role (permissions_boundary set)
#                            and the session is time-bounded (max_session_duration).
#
# Runs at `command = plan` against a mocked AWS provider (no account, no network).
# aws_caller_identity / aws_partition are mocked so `arn:aws:...:root` principals
# render with a real partition; every policy under assertion is built with
# jsonencode() inline, so its content is REAL and known at plan time. Assertions are
# STRUCTURAL — statements are located by Sid or by their Action, never by position —
# so reordering statements can never mask a regression.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDTEST"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }
  # The provider validates that ok_actions/alarm_actions, the SNS topic-policy arn,
  # and the role's permissions_boundary are syntactically valid ARNs at plan time.
  # A random mock string fails those validators, so pin real ARNs for the .arn
  # attributes those fields consume (the values are otherwise irrelevant to the
  # security assertions — boundary attachment is proven by equality, not by value).
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:us-west-2:123456789012:development-break-glass-alert"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/development-break-glass-boundary"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-west-2:123456789012:key/break-glass"
    }
  }
  # The EventBridge topic policy scopes aws:SourceArn to this rule's ARN; pin it so
  # the jsonencode'd policy is fully known at plan and the SourceArn assertion is real.
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-west-2:123456789012:rule/development-break-glass-detection"
    }
  }
}

variables {
  environment                 = "development"
  region                      = "us-west-2"
  team                        = "platform"
  trusted_account_ids         = ["123456789012"]
  enable_permissions_boundary = true
  max_session_duration        = 3600
}

# INVARIANT 1 — the MFA gate. Exactly one trust statement, and it must carry the
# aws:MultiFactorAuthPresent=true Bool condition. Delete the condition and the role
# is assumable from a trusted account with no second factor.
run "assume_requires_mfa" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.break_glass.assume_role_policy).Statement :
      s if try(s.Condition.Bool["aws:MultiFactorAuthPresent"], "") == "true"
    ]) == 1
    error_message = "break-glass assume-role must require aws:MultiFactorAuthPresent=true on the trust statement"
  }
}

# INVARIANT 2 — the trust is scoped to the trusted accounts' root ARNs, and to
# nothing else. Asserted as an EXACT match of Principal.AWS, which bites both a
# widened wildcard ("*" or ["*"]) and any extra/wrong account slipping into the list.
run "trust_scoped_to_trusted_roots_never_wildcard" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.break_glass.assume_role_policy).Statement :
      s if try(s.Effect, "") == "Allow"
      && try(s.Action, "") == "sts:AssumeRole"
      && try(s.Principal.AWS, null) == ["arn:aws:iam::123456789012:root"]
    ]) == 1
    error_message = "break-glass trust Principal.AWS must be exactly the trusted accounts' root ARNs, never \"*\""
  }
}

# INVARIANT 3 — the boundary is the ceiling. The DenyIAMModifications statement must
# be an explicit Deny covering every IAM identity-write verb AND organizations:*, so
# the emergency admin can neither self-escalate (mint/alter roles & policies) nor
# re-org the account to persist. Located by Sid; every verb checked individually so
# dropping any one from the Deny list fails the assertion. The session-persistence
# and escalation verbs (mint an access key, attach/inline a user policy, publish a
# new default policy version, rewrite a trust policy, strip/replace a permissions
# boundary, chain into another role via sts:AssumeRole) are all covered too.
run "boundary_denies_self_escalation" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.boundary[0].policy).Statement :
      s if try(s.Sid, "") == "DenyIAMModifications"
      && try(s.Effect, "") == "Deny"
      && contains(try(s.Action, []), "iam:CreateRole")
      && contains(try(s.Action, []), "iam:DeleteRole")
      && contains(try(s.Action, []), "iam:CreatePolicy")
      && contains(try(s.Action, []), "iam:DeletePolicy")
      && contains(try(s.Action, []), "iam:AttachRolePolicy")
      && contains(try(s.Action, []), "iam:DetachRolePolicy")
      && contains(try(s.Action, []), "iam:PutRolePolicy")
      && contains(try(s.Action, []), "iam:DeleteRolePolicy")
      && contains(try(s.Action, []), "iam:CreateAccessKey")
      && contains(try(s.Action, []), "iam:AttachUserPolicy")
      && contains(try(s.Action, []), "iam:PutUserPolicy")
      && contains(try(s.Action, []), "iam:CreatePolicyVersion")
      && contains(try(s.Action, []), "iam:UpdateAssumeRolePolicy")
      && contains(try(s.Action, []), "iam:PutRolePermissionsBoundary")
      && contains(try(s.Action, []), "sts:AssumeRole")
      && contains(try(s.Action, []), "organizations:*")
    ]) == 1
    error_message = "break-glass boundary DenyIAMModifications must Deny all IAM identity-write, session-persistence, and escalation verbs (CreateAccessKey, Attach/PutUserPolicy, CreatePolicyVersion, UpdateAssumeRolePolicy, PutRolePermissionsBoundary, sts:AssumeRole) plus organizations:*"
  }
}

# INVARIANT 5 — the assumption-alert topic is encrypted at rest with a CMK whose
# policy admits the CloudWatch-alarm and EventBridge publishers. If the topic were
# unencrypted, or the key policy omitted those service principals, the alert that
# makes break-glass auditable would either leak at rest or never fire.
run "alert_topic_encrypted_with_publisher_grant" {
  command = plan

  assert {
    condition     = aws_sns_topic.break_glass.kms_master_key_id == "arn:aws:kms:us-west-2:123456789012:key/break-glass"
    error_message = "break-glass alert topic must set kms_master_key_id to the CMK ARN (SSE-KMS)"
  }

  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.break_glass.policy).Statement :
      s if try(s.Effect, "") == "Allow"
      && contains(try(s.Principal.Service, []), "cloudwatch.amazonaws.com")
      && contains(try(s.Principal.Service, []), "events.amazonaws.com")
      && contains(try(s.Action, []), "kms:GenerateDataKey*")
      && contains(try(s.Action, []), "kms:Decrypt")
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
    ]) == 1
    error_message = "break-glass alert CMK policy must grant cloudwatch + events kms:GenerateDataKey*/Decrypt scoped by SourceAccount"
  }
}

# INVARIANT 6 — the assumption-alert topic's resource policy scopes the EventBridge
# publish grant by aws:SourceAccount AND aws:SourceArn (the specific detection rule).
# Those are the confused-deputy guards: without them the events service principal
# acting for any account/rule could publish to (or forge alerts on) the break-glass
# topic. Located by Sid, so statement reordering can't mask a regression.
run "eventbridge_publish_scoped_by_source" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_sns_topic_policy.break_glass_eventbridge.policy).Statement :
      s if try(s.Sid, "") == "AllowEventBridge"
      && try(s.Effect, "") == "Allow"
      && try(s.Principal.Service, "") == "events.amazonaws.com"
      && try(s.Action, "") == "SNS:Publish"
      && try(s.Condition.StringEquals["aws:SourceAccount"], "") == "123456789012"
      && try(s.Condition.ArnEquals["aws:SourceArn"], "") == "arn:aws:events:us-west-2:123456789012:rule/development-break-glass-detection"
    ]) == 1
    error_message = "break-glass EventBridge topic policy must grant SNS:Publish to events.amazonaws.com scoped by both aws:SourceAccount and aws:SourceArn (the detection rule ARN)"
  }
}

# INVARIANT 4 — the Deny above is inert unless the boundary policy is actually bound
# to the role, and the emergency session is time-bounded. permissions_boundary must
# equal the boundary policy's ARN (not null), and max_session_duration must equal the
# bounded value passed in (an unbounded/hardcoded max is a standing-admin risk).
run "boundary_attached_and_session_bounded" {
  command = plan

  assert {
    condition     = aws_iam_role.break_glass.permissions_boundary == aws_iam_policy.boundary[0].arn
    error_message = "break-glass role must have its permissions_boundary set to the boundary policy ARN when enabled"
  }

  assert {
    condition     = aws_iam_role.break_glass.max_session_duration == 3600
    error_message = "break-glass max_session_duration must equal the bounded value passed in (3600s)"
  }
}
