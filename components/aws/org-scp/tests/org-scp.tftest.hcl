# Unit tests for org-scp — the Service Control Policy factory that sets the org's
# guardrail ceiling. This component is generic: the caller hands it each policy's
# raw JSON `content` and `target_ids` in var.policies, and the component must
# (1) thread that JSON onto a real aws_organizations_policy WITHOUT mangling it,
# (2) type it as a SERVICE_CONTROL_POLICY (any other type never enforces a Deny),
# and (3) fan out one attachment per (policy, target) so EVERY target is actually
# governed. An SCP that is silently re-typed, whose content is dropped/rewritten,
# or that is created but never attached is a toothless guardrail — the account
# could then LeaveOrganization, StopLogging on CloudTrail, delete the GuardDuty
# detector / Config recorder, or operate outside the pinned regions. These tests
# feed a realistic guardrail SCP and assert those Deny statements land intact on
# the rendered resource, that the type is SCP, and that every target is attached.
#
# Runs at `command = plan` against a mocked AWS provider (no account, no network).
# aws_caller_identity / aws_region are mocked so the data sources resolve. The SCP
# `content` and `type` are configured arguments (known at plan), so the mock does
# NOT synthesize them — jsondecode(aws_organizations_policy.this[...].content) sees
# the real value the component threaded through, which is exactly what we assert.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDTEST"
    }
  }
  mock_data "aws_region" {
    defaults = {
      name        = "us-west-2"
      description = "US West (Oregon)"
    }
  }
}

variables {
  environment = "development"
  region      = "us-west-2"
  team        = "platform"

  # A realistic org guardrail ceiling. Built with jsonencode() so the JSON is real
  # and known at plan time. target_ids has TWO entries so the attachment fan-out
  # (the flatten in locals) is actually exercised — a single target would hide a
  # "only attaches the first target" regression.
  policies = {
    guardrails = {
      description = "Org guardrail ceiling: deny org-escape and guardrail-disable verbs"
      target_ids  = ["ou-a1b2-c3d4e5f6", "999988887777"]
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DenyLeaveOrganization"
            Effect   = "Deny"
            Action   = ["organizations:LeaveOrganization"]
            Resource = "*"
          },
          {
            Sid      = "DenyCloudTrailTamper"
            Effect   = "Deny"
            Action   = ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail"]
            Resource = "*"
          },
          {
            Sid      = "DenyGuardDutyDisable"
            Effect   = "Deny"
            Action   = ["guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount"]
            Resource = "*"
          },
          {
            Sid      = "DenyConfigDisable"
            Effect   = "Deny"
            Action   = ["config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder"]
            Resource = "*"
          },
          {
            Sid       = "DenyOutsideAllowedRegions"
            Effect    = "Deny"
            NotAction = ["iam:*", "organizations:*", "cloudtrail:*", "sts:*"]
            Resource  = "*"
            Condition = {
              StringNotEquals = {
                "aws:RequestedRegion" = ["us-west-2", "us-east-1"]
              }
            }
          },
        ]
      })
    }
  }
}

# The guardrail ceiling must Deny the org-escape / guardrail-disable verbs, and the
# component must carry those statements onto the real resource unchanged. Asserted
# structurally — find each statement by (Effect==Deny + action membership), never by
# position — so statement reordering or an extra statement can't mask a dropped Deny.
run "guardrail_denies_org_escape_verbs" {
  command = plan

  # organizations:LeaveOrganization — the account can never detach from the org.
  assert {
    condition = length([
      for s in jsondecode(aws_organizations_policy.this["guardrails"].content).Statement :
      s if s.Effect == "Deny" && contains(try(s.Action, []), "organizations:LeaveOrganization")
    ]) == 1
    error_message = "guardrail SCP must Deny organizations:LeaveOrganization (org-escape)"
  }

  # CloudTrail can never be silenced — both StopLogging and DeleteTrail denied in one stmt.
  assert {
    condition = length([
      for s in jsondecode(aws_organizations_policy.this["guardrails"].content).Statement :
      s if s.Effect == "Deny"
      && contains(try(s.Action, []), "cloudtrail:StopLogging")
      && contains(try(s.Action, []), "cloudtrail:DeleteTrail")
    ]) == 1
    error_message = "guardrail SCP must Deny cloudtrail:StopLogging AND cloudtrail:DeleteTrail (audit-trail tamper)"
  }

  # GuardDuty detector can never be deleted / disassociated.
  assert {
    condition = length([
      for s in jsondecode(aws_organizations_policy.this["guardrails"].content).Statement :
      s if s.Effect == "Deny" && contains(try(s.Action, []), "guardduty:DeleteDetector")
    ]) == 1
    error_message = "guardrail SCP must Deny guardduty:DeleteDetector (threat-detection disable)"
  }

  # Config recorder can never be stopped / deleted.
  assert {
    condition = length([
      for s in jsondecode(aws_organizations_policy.this["guardrails"].content).Statement :
      s if s.Effect == "Deny" && contains(try(s.Action, []), "config:StopConfigurationRecorder")
    ]) == 1
    error_message = "guardrail SCP must Deny config:StopConfigurationRecorder (config-recording disable)"
  }
}

# The region restriction: a Deny keyed on aws:RequestedRegion StringNotEquals. If this
# condition is dropped, workloads can spin up in un-monitored regions.
run "guardrail_pins_regions" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_organizations_policy.this["guardrails"].content).Statement :
      s if s.Effect == "Deny"
      && try(s.Condition.StringNotEquals["aws:RequestedRegion"], null) != null
    ]) == 1
    error_message = "guardrail SCP must Deny actions outside the pinned regions via aws:RequestedRegion StringNotEquals"
  }
}

# The policy MUST be a SERVICE_CONTROL_POLICY. A TAG_POLICY / BACKUP_POLICY with the
# same JSON never enforces a Deny — it would be a guardrail that does nothing.
run "policy_is_service_control_policy_type" {
  command = plan

  assert {
    condition     = aws_organizations_policy.this["guardrails"].type == "SERVICE_CONTROL_POLICY"
    error_message = "org guardrail must be created as type SERVICE_CONTROL_POLICY; any other type does not enforce Deny"
  }
}

# A guardrail that is created but not attached governs nothing. The flatten must
# produce exactly one attachment per target_id, each routed to the correct target.
run "policy_attached_to_every_target" {
  command = plan

  # Completeness: two targets in → two attachments out (catches a fan-out that only
  # attaches the first target).
  assert {
    condition     = length(aws_organizations_policy_attachment.this) == 2
    error_message = "guardrails SCP must be attached to every target_id (expected 2 attachments)"
  }

  # Correct routing: every attachment lands on one of the supplied targets, never a
  # hardcoded / wrong OU or account.
  assert {
    condition = alltrue([
      for k, a in aws_organizations_policy_attachment.this :
      contains(["ou-a1b2-c3d4e5f6", "999988887777"], a.target_id)
    ])
    error_message = "each SCP attachment must target one of the supplied target_ids, not a wrong/hardcoded target"
  }
}
