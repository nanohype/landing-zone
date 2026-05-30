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

    EnforceMandatoryTags = {
      description = "Deny resource creation without PlatformId and DataClassification tags"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenyCreateWithoutMandatoryTags"
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
                "aws:RequestTag/PlatformId"         = "true"
                "aws:RequestTag/DataClassification" = "true"
              }
            }
          },
        ]
      })
    }

    # Org-level defense-in-depth atop the per-key encryption-context enforcement
    # the eks-agent-platform operator already applies (its KMS grants always set
    # EncryptionContextEquals {PlatformId}). Bites operator-managed data keys
    # (ManagedBy=eks-agent-platform); the opentofu-managed secrets/logs keys use
    # a different context key and stay out of scope. Verify the data CMK carries
    # this ManagedBy value before attaching to a live OU.
    DenyKmsDecryptWithoutPlatformContext = {
      description = "Deny KMS decrypt on platform-managed keys without PlatformId encryption context"
      target_ids  = []
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "DenyDecryptWithoutPlatformContext"
            Effect   = "Deny"
            Action   = "kms:Decrypt"
            Resource = "arn:aws:kms:*:*:key/*"
            Condition = {
              StringEquals = {
                "aws:ResourceTag/ManagedBy" = "eks-agent-platform"
              }
              Null = {
                "kms:EncryptionContext:PlatformId" = "true"
              }
            }
          },
        ]
      })
    }
  }
}
