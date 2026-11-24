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
#
# The component also ships nine guardrail SCPs of its own (guardrails.tf). The runs
# at the end hold each one to its exact Deny statements, so a guardrail that is
# gutted, narrowed, widened or turned into an Allow fails here rather than shipping;
# a deliberate change to a guardrail changes its assertion in the same pull request.
# They also bind each guardrail only where guardrail_targets says, and refuse a
# target for a guardrail that does not exist or an operator policy that would
# replace one.

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
      name        = "us-east-1"
      description = "US West (Oregon)"
    }
  }
}

variables {
  environment     = "development"
  region          = "us-east-1"
  team            = "platform"
  allowed_regions = ["us-east-1"]

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
                "aws:RequestedRegion" = ["us-east-1", "us-east-1"]
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

# ── the shipped guardrails ────────────────────────────────────────────────────

# With no operator policies, the component creates exactly the nine guardrails and
# attaches none of them.
run "ships_the_nine_guardrails_attached_to_nothing" {
  command = plan

  variables {
    policies = {}
  }

  assert {
    condition     = toset(keys(aws_organizations_policy.this)) == toset(["DenyLeavingOrg", "DenyDisablingSecurity", "DenyRootUserActions", "RegionRestriction", "NetworkGuardrails", "DataProtection", "DenyBedrockEgressOutsideRegion", "EnforceMandatoryTags", "DenyDirectUseOfPlatformKeys"])
    error_message = "with no operator policies the component must create exactly its nine guardrails"
  }

  assert {
    condition     = length(aws_organizations_policy_attachment.this) == 0
    error_message = "a guardrail with no guardrail_targets entry must be attached nowhere"
  }

  assert {
    condition     = alltrue([for p in aws_organizations_policy.this : p.type == "SERVICE_CONTROL_POLICY"])
    error_message = "every guardrail must be a SERVICE_CONTROL_POLICY"
  }
}

# Each shipped guardrail, statement by statement.
run "each_shipped_guardrail_holds_exactly_its_deny_statements" {
  command = plan

  variables {
    policies = {}
  }

  assert {
    condition = jsondecode(aws_organizations_policy.this["DenyLeavingOrg"].content).Statement == [
      {
        Action   = "organizations:LeaveOrganization"
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyLeaveOrganization"
      },
    ]
    error_message = "the shipped DenyLeavingOrg guardrail must hold exactly its Deny statements; a change to it is a change to this assertion too"
  }
  assert {
    condition = jsondecode(aws_organizations_policy.this["DenyDisablingSecurity"].content).Statement == [
      {
        Action   = ["cloudtrail:DeleteTrail", "cloudtrail:StopLogging", "cloudtrail:UpdateTrail", "guardduty:DeleteDetector", "guardduty:DisassociateFromMasterAccount", "guardduty:UpdateDetector", "config:DeleteConfigurationRecorder", "config:DeleteDeliveryChannel", "config:StopConfigurationRecorder", "securityhub:DisableSecurityHub", "securityhub:DeleteMembers", "securityhub:DisassociateFromMasterAccount", "access-analyzer:DeleteAnalyzer"]
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyDisablingSecurityServices"
      },
    ]
    error_message = "the shipped DenyDisablingSecurity guardrail must hold exactly its Deny statements; a change to it is a change to this assertion too"
  }
  assert {
    condition = jsondecode(aws_organizations_policy.this["DenyRootUserActions"].content).Statement == [
      {
        Action = "*"
        Condition = {
          StringLike = {
            "aws:PrincipalArn" = "arn:aws:iam::*:root"
          }
        }
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyRootUserActions"
      },
    ]
    error_message = "the shipped DenyRootUserActions guardrail must hold exactly its Deny statements; a change to it is a change to this assertion too"
  }
  assert {
    condition = jsondecode(aws_organizations_policy.this["RegionRestriction"].content).Statement == [
      {
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = ["us-east-1"]
          }
        }
        Effect    = "Deny"
        NotAction = ["a4b:*", "budgets:*", "ce:*", "chime:*", "cloudfront:*", "cur:*", "globalaccelerator:*", "health:*", "iam:*", "importexport:*", "organizations:*", "route53:*", "route53domains:*", "shield:*", "sts:*", "support:*", "trustedadvisor:*", "waf:*"]
        Resource  = "*"
        Sid       = "DenyOutsideAllowedRegions"
      },
    ]
    error_message = "the shipped RegionRestriction guardrail must hold exactly its Deny statements; a change to it is a change to this assertion too"
  }
  assert {
    condition = jsondecode(aws_organizations_policy.this["NetworkGuardrails"].content).Statement == [
      {
        Action   = "ec2:CreateDefaultVpc"
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyDefaultVPC"
      },
      {
        Action   = "ec2:DeleteFlowLogs"
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyDeleteFlowLogs"
      },
      {
        Action   = "ec2:DisableEbsEncryptionByDefault"
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyDisableEBSEncryption"
      },
    ]
    error_message = "the shipped NetworkGuardrails guardrail must hold exactly its Deny statements; a change to it is a change to this assertion too"
  }
  assert {
    condition = jsondecode(aws_organizations_policy.this["DataProtection"].content).Statement == [
      {
        Action   = "s3:PutBucketPublicAccessBlock"
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyRemovingS3PublicAccessBlock"
      },
      {
        Action = "s3:PutObject"
        Condition = {
          Null = {
            "s3:x-amz-server-side-encryption" = "false"
          }
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = ["AES256", "aws:kms"]
          }
        }
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyUnencryptedS3Puts"
      },
      {
        Action = ["rds:CreateDBInstance", "rds:CreateDBCluster"]
        Condition = {
          Bool = {
            "rds:StorageEncrypted" = "false"
          }
        }
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyUnencryptedResources"
      },
      {
        Action = "ec2:CreateVolume"
        Condition = {
          Bool = {
            "ec2:Encrypted" = "false"
          }
        }
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyUnencryptedEBSVolumes"
      },
    ]
    error_message = "the shipped DataProtection guardrail must hold exactly its Deny statements; a change to it is a change to this assertion too"
  }
  assert {
    condition = jsondecode(aws_organizations_policy.this["DenyBedrockEgressOutsideRegion"].content).Statement == [
      {
        Action = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream"]
        Condition = {
          StringNotEquals = {
            "aws:RequestedRegion" = ["us-east-1"]
          }
        }
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyBedrockInvokeOutsideSanctionedRegions"
      },
    ]
    error_message = "the shipped DenyBedrockEgressOutsideRegion guardrail must hold exactly its Deny statements; a change to it is a change to this assertion too"
  }
  assert {
    condition = jsondecode(aws_organizations_policy.this["EnforceMandatoryTags"].content).Statement == [
      {
        Action = ["ec2:RunInstances", "ec2:CreateVolume", "lambda:CreateFunction", "s3:CreateBucket", "dynamodb:CreateTable", "rds:CreateDBInstance", "rds:CreateDBCluster", "sqs:CreateQueue", "sns:CreateTopic"]
        Condition = {
          Null = {
            "aws:RequestTag/PlatformId" = "true"
          }
        }
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyCreateWithoutPlatformId"
      },
      {
        Action = ["ec2:RunInstances", "ec2:CreateVolume", "lambda:CreateFunction", "s3:CreateBucket", "dynamodb:CreateTable", "rds:CreateDBInstance", "rds:CreateDBCluster", "sqs:CreateQueue", "sns:CreateTopic"]
        Condition = {
          Null = {
            "aws:RequestTag/DataClassification" = "true"
          }
        }
        Effect   = "Deny"
        Resource = "*"
        Sid      = "DenyCreateWithoutDataClassification"
      },
    ]
    error_message = "the shipped EnforceMandatoryTags guardrail must hold exactly its Deny statements; a change to it is a change to this assertion too"
  }
  assert {
    condition = jsondecode(aws_organizations_policy.this["DenyDirectUseOfPlatformKeys"].content).Statement == [
      {
        Action = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*"]
        Condition = {
          "ForAnyValue:StringLike" = {
            "kms:ResourceAliases" = ["alias/*-platform-secrets", "alias/*-platform-logs"]
          }
          Null = {
            "kms:ViaService" = "true"
          }
        }
        Effect   = "Deny"
        Resource = "arn:aws:kms:*:*:key/*"
        Sid      = "DenyDirectUseOfPlatformKeys"
      },
    ]
    error_message = "the shipped DenyDirectUseOfPlatformKeys guardrail must hold exactly its Deny statements; a change to it is a change to this assertion too"
  }
}

# The region guardrails deny outside allowed_regions, whatever it holds.
# region-ok: us-west-2 is the second allowed region in this run; a list that only
# held the deploy region could not tell the input apart from a hard-coded value.
run "region_guardrails_follow_allowed_regions" {
  command = plan

  variables {
    policies        = {}
    allowed_regions = ["us-east-1", "us-west-2"]
  }

  assert {
    condition = alltrue([
      for name in ["RegionRestriction", "DenyBedrockEgressOutsideRegion"] :
      jsondecode(aws_organizations_policy.this[name].content).Statement[0].Condition.StringNotEquals["aws:RequestedRegion"] == ["us-east-1", "us-west-2"]
    ])
    error_message = "RegionRestriction and DenyBedrockEgressOutsideRegion must deny outside exactly allowed_regions"
  }
}

# A guardrail binds where guardrail_targets names, and nowhere else.
run "a_guardrail_binds_only_where_targeted" {
  command = plan

  variables {
    policies          = {}
    guardrail_targets = { DenyLeavingOrg = ["ou-a1b2-c3d4e5f6"] }
  }

  assert {
    condition     = keys(aws_organizations_policy_attachment.this) == ["DenyLeavingOrg-ou-a1b2-c3d4e5f6"]
    error_message = "guardrail_targets must attach DenyLeavingOrg to its one target and attach nothing else"
  }

  assert {
    condition     = aws_organizations_policy_attachment.this["DenyLeavingOrg-ou-a1b2-c3d4e5f6"].target_id == "ou-a1b2-c3d4e5f6"
    error_message = "the attachment must land on the named target"
  }
}

run "a_target_for_an_unknown_guardrail_is_refused" {
  command = plan

  variables {
    guardrail_targets = { DenyEverything = ["ou-a1b2-c3d4e5f6"] }
  }

  expect_failures = [var.guardrail_targets]
}

run "an_operator_policy_may_not_replace_a_guardrail" {
  command = plan

  variables {
    policies = {
      DenyLeavingOrg = {
        description = "an empty policy under a guardrail's name"
        policy      = jsonencode({ Version = "2012-10-17", Statement = [] })
        target_ids  = []
      }
    }
  }

  expect_failures = [var.policies]
}

run "allowed_regions_must_name_a_region" {
  command = plan

  variables {
    allowed_regions = []
  }

  expect_failures = [var.allowed_regions]
}
