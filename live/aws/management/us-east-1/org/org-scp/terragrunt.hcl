include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/org-scp.hcl"
  merge_strategy = "deep"
}

inputs = {
  policies = {
    DenyLeavingOrg = {
      description = "Prevent accounts from leaving the organization"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DenyLeaveOrganization"
            Effect   = "Deny"
            Action   = "organizations:LeaveOrganization"
            Resource = "*"
          },
        ]
      })
    }

    DenyDisablingSecurity = {
      description = "Prevent disabling security services"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyDisablingSecurityServices"
            Effect = "Deny"
            Action = [
              "cloudtrail:DeleteTrail",
              "cloudtrail:StopLogging",
              "cloudtrail:UpdateTrail",
              "guardduty:DeleteDetector",
              "guardduty:DisassociateFromMasterAccount",
              "guardduty:UpdateDetector",
              "config:DeleteConfigurationRecorder",
              "config:DeleteDeliveryChannel",
              "config:StopConfigurationRecorder",
              "securityhub:DisableSecurityHub",
              "securityhub:DeleteMembers",
              "securityhub:DisassociateFromMasterAccount",
              "access-analyzer:DeleteAnalyzer",
            ]
            Resource = "*"
          },
        ]
      })
    }

    DenyRootUserActions = {
      description = "Deny actions by root user"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DenyRootUserActions"
            Effect   = "Deny"
            Action   = "*"
            Resource = "*"
            Condition = {
              StringLike = {
                "aws:PrincipalArn" = "arn:aws:iam::*:root"
              }
            }
          },
        ]
      })
    }

    RegionRestriction = {
      description = "Restrict actions to allowed regions"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyOutsideAllowedRegions"
            Effect = "Deny"
            NotAction = [
              "a4b:*",
              "budgets:*",
              "ce:*",
              "chime:*",
              "cloudfront:*",
              "cur:*",
              "globalaccelerator:*",
              "health:*",
              "iam:*",
              "importexport:*",
              "organizations:*",
              "route53:*",
              "route53domains:*",
              "shield:*",
              "sts:*",
              "support:*",
              "trustedadvisor:*",
              "waf:*",
            ]
            Resource = "*"
            Condition = {
              StringNotEquals = {
                "aws:RequestedRegion" = [
                  "us-east-1",
                  "us-west-2",
                ]
              }
            }
          },
        ]
      })
    }

    NetworkGuardrails = {
      description = "Prevent insecure network configurations"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DenyDefaultVPC"
            Effect   = "Deny"
            Action   = "ec2:CreateDefaultVpc"
            Resource = "*"
          },
          {
            Sid      = "DenyDeleteFlowLogs"
            Effect   = "Deny"
            Action   = "ec2:DeleteFlowLogs"
            Resource = "*"
          },
          {
            Sid      = "DenyDisableEBSEncryption"
            Effect   = "Deny"
            Action   = "ec2:DisableEbsEncryptionByDefault"
            Resource = "*"
          },
        ]
      })
    }

    DataProtection = {
      description = "Enforce data protection controls"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DenyRemovingS3PublicAccessBlock"
            Effect   = "Deny"
            Action   = "s3:PutBucketPublicAccessBlock"
            Resource = "*"
          },
          {
            Sid      = "DenyUnencryptedS3Puts"
            Effect   = "Deny"
            Action   = "s3:PutObject"
            Resource = "*"
            Condition = {
              StringNotEquals = {
                "s3:x-amz-server-side-encryption" = ["AES256", "aws:kms"]
              }
              Null = {
                "s3:x-amz-server-side-encryption" = "false"
              }
            }
          },
          {
            Sid    = "DenyUnencryptedResources"
            Effect = "Deny"
            Action = [
              "rds:CreateDBInstance",
              "rds:CreateDBCluster",
            ]
            Resource = "*"
            Condition = {
              Bool = {
                "rds:StorageEncrypted" = "false"
              }
            }
          },
          {
            Sid      = "DenyUnencryptedEBSVolumes"
            Effect   = "Deny"
            Action   = "ec2:CreateVolume"
            Resource = "*"
            Condition = {
              Bool = {
                "ec2:Encrypted" = "false"
              }
            }
          },
        ]
      })
    }

    # Bedrock is reached in-region (agentgateway + IRSA callers all invoke in
    # us-west-2 / us-east-1); there is no Bedrock VPC endpoint to key on, and
    # SCPs gate API actions, not the cloudflared MCP tunnel's network egress.
    # So the sanctioned-egress guardrail is region-pinning, mirroring
    # RegionRestriction but scoped to model invocation.
    DenyBedrockEgressOutsideRegion = {
      description = "Deny Bedrock model invocation outside sanctioned regions"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyBedrockInvokeOutsideSanctionedRegions"
            Effect = "Deny"
            Action = [
              "bedrock:InvokeModel",
              "bedrock:InvokeModelWithResponseStream",
              "bedrock:Converse",
              "bedrock:ConverseStream",
            ]
            Resource = "*"
            Condition = {
              StringNotEquals = {
                "aws:RequestedRegion" = [
                  "us-east-1",
                  "us-west-2",
                ]
              }
            }
          },
        ]
      })
    }

    # ONE STATEMENT PER TAG, and that is the whole point. IAM ANDs every key inside
    # a single Condition block, so putting both Null checks together denies only
    # when BOTH tags are absent — a resource carrying one and missing the other
    # sails through. That is not a theoretical gap here: live/root.hcl injects
    # DataClassification into default_tags on every resource this repo creates, so
    # that key is never absent, so the AND is never satisfied, so a combined
    # statement can never fire at all. It would read as enforcement and deny
    # nothing, forever.
    #
    # Two statements means each tag is independently required: absent PlatformId
    # denies regardless of DataClassification, and vice versa.
    EnforceMandatoryTags = {
      description = "Deny resource creation missing EITHER the PlatformId or the DataClassification tag (one statement per tag — a combined Null block would AND them and never fire)"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          for tag in ["PlatformId", "DataClassification"] : {
            Sid    = "DenyCreateWithout${tag}"
            Effect = "Deny"
            Action = [
              "ec2:RunInstances",
              "ec2:CreateVolume",
              "lambda:CreateFunction",
              "s3:CreateBucket",
              "dynamodb:CreateTable",
              "rds:CreateDBInstance",
              "rds:CreateDBCluster",
              "sqs:CreateQueue",
              "sns:CreateTopic",
            ]
            Resource = "*"
            Condition = {
              Null = {
                "aws:RequestTag/${tag}" = "true"
              }
            }
          }
        ]
      })
    }

    # Deny DIRECT use of the two platform CMKs. Every legitimate use of them is
    # mediated by a service — Secrets Manager for secrets, CloudWatch Logs for log
    # groups, S3 for the artifacts, cost and Bedrock-invocation buckets — and
    # kms:ViaService is populated only on those forward-access sessions. A request
    # that reaches these keys with ViaService absent is a principal calling KMS
    # directly with ciphertext it already holds, which is the exfiltration shape and
    # not any path this platform uses.
    #
    # This replaces a Deny that keyed on `kms:EncryptionContext:PlatformId` being
    # null. That condition is null on EVERY S3-mediated decrypt there is, because S3
    # supplies its own context (`aws:s3:arn`) and never a PlatformId pair — so the
    # old form would have denied every tenant reading its own artifacts the moment it
    # was attached. It justified itself by pointing at operator KMS grants that could
    # not authorize an S3 operation and were removed in
    # nanohype/eks-agent-platform#168.
    #
    # Scoped by ALIAS, which exists, rather than by ManagedBy=eks-agent-platform,
    # which no key carries: the operator mints no keys. The two aliases are the
    # secrets key and — where an environment sets separate_logs_key — the logs key.
    #
    # Tenant CMKs are deliberately OUT of scope. tenant-substrate aliases them
    # `<prefix>-tenant`, and a tenant's envelope-encryption pattern is a DIRECT
    # GenerateDataKey/Decrypt by design (see tenant-key-access), so denying direct
    # use of those would break the thing they exist for.
    #
    # target_ids stays empty. Attaching an SCP is an org-wide act with no undo path
    # for whoever is locked out, and this repo does not decide that.
    DenyDirectUseOfPlatformKeys = {
      description = "Deny direct KMS use of the platform CMKs — service-mediated access only"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyDirectUseOfPlatformKeys"
            Effect = "Deny"
            Action = [
              "kms:Decrypt",
              "kms:GenerateDataKey*",
              "kms:ReEncrypt*",
            ]
            Resource = "arn:aws:kms:*:*:key/*"
            Condition = {
              # Multi-valued key, so ForAnyValue is correct here — a key matches if
              # ANY of its aliases is one of the platform two.
              "ForAnyValue:StringLike" = {
                "kms:ResourceAliases" = [
                  "alias/*-platform-secrets",
                  "alias/*-platform-logs",
                ]
              }
              # ViaService is populated only on a forward-access session, so its
              # absence IS the direct call this denies.
              Null = {
                "kms:ViaService" = "true"
              }
            }
          },
        ]
      })
    }
  }
}
