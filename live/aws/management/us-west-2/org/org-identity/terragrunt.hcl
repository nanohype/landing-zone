include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/org-identity.hcl"
  merge_strategy = "deep"
}

inputs = {
  permission_sets = {
    Admin = {
      description      = "Full administrator access"
      session_duration = "PT4H"
      managed_policies = ["arn:aws:iam::aws:policy/AdministratorAccess"]
      inline_policy    = null
      boundary_policy  = null
    }
    PowerUser = {
      description      = "Power user access (no IAM management)"
      session_duration = "PT8H"
      managed_policies = ["arn:aws:iam::aws:policy/PowerUserAccess"]
      inline_policy    = null
      boundary_policy  = null
    }
    ReadOnly = {
      description      = "Read-only access to all resources"
      session_duration = "PT12H"
      managed_policies = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      inline_policy    = null
      boundary_policy  = null
    }
    PlatformEngineer = {
      description      = "Platform engineering access"
      session_duration = "PT8H"
      managed_policies = ["arn:aws:iam::aws:policy/PowerUserAccess"]
      inline_policy    = null
      boundary_policy  = null
    }
    Developer = {
      description      = "Developer access for workloads"
      session_duration = "PT8H"
      managed_policies = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      inline_policy    = null
      boundary_policy  = null
    }

    # Tenant-facing human SSO personas (distinct from per-tenant pod IRSA, which
    # the eks-agent-platform operator mints). Scoped on the nanohype tenant tag
    # key PlatformId — claudium's Workspace tag is never used in this org.
    PlatformAdmin = {
      description      = "Full platform admin on the management account"
      session_duration = "PT1H"
      managed_policies = []
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "PlatformAdminAllow"
            Effect = "Allow"
            Action = [
              "organizations:*",
              "sso:*",
              "identitystore:*",
              "iam:*",
              "cloudformation:*",
            ]
            Resource = "*"
          },
          {
            Sid    = "DenyReservedRoleMutation"
            Effect = "Deny"
            Action = [
              "iam:DeleteRole",
              "iam:DeleteRolePolicy",
            ]
            Resource = [
              "arn:aws:iam::*:role/aws-reserved/*",
              "arn:aws:iam::*:role/*-Auditor",
            ]
          },
        ]
      })
      boundary_policy = null
    }

    TenantAdmin = {
      description      = "Admin scoped to PlatformId-tagged tenant resources"
      session_duration = "PT1H"
      managed_policies = []
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "TenantAdminScoped"
            Effect = "Allow"
            Action = [
              "kms:*",
              "secretsmanager:*",
              "logs:*",
              "s3:*",
              "cloudwatch:*",
              "ssm:*",
            ]
            Resource = "*"
            Condition = {
              Null = {
                "aws:ResourceTag/PlatformId" = "false"
              }
            }
          },
        ]
      })
      boundary_policy = null
    }

    TenantDeveloper = {
      description      = "Runtime invoke + read-only logs on PlatformId-tagged tenant resources"
      session_duration = "PT1H"
      managed_policies = []
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "TenantDeveloperRuntime"
            Effect = "Allow"
            Action = [
              "execute-api:Invoke",
              "lambda:InvokeFunction",
              "sqs:SendMessage",
            ]
            Resource = "*"
            Condition = {
              Null = {
                "aws:ResourceTag/PlatformId" = "false"
              }
            }
          },
          {
            Sid    = "TenantDeveloperRead"
            Effect = "Allow"
            Action = [
              "logs:GetLogEvents",
              "logs:FilterLogEvents",
              "cloudwatch:GetMetricData",
            ]
            Resource = "*"
          },
        ]
      })
      boundary_policy = null
    }

    Auditor = {
      description      = "Read-only auditor — logs/athena/glue read, explicit data-plane deny"
      session_duration = "PT4H"
      managed_policies = ["arn:aws:iam::aws:policy/SecurityAudit"]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "AuditorReadLogs"
            Effect = "Allow"
            Action = [
              "logs:GetLogEvents",
              "logs:FilterLogEvents",
              "logs:DescribeLogGroups",
              "athena:*",
              "glue:GetDatabase",
              "glue:GetTable",
              "glue:GetPartitions",
              "s3:GetObject",
              "s3:ListBucket",
            ]
            Resource = "*"
          },
          {
            Sid      = "AuditorDenyDataPlaneSecrets"
            Effect   = "Deny"
            Action   = "secretsmanager:GetSecretValue"
            Resource = "*"
          },
        ]
      })
      boundary_policy = null
    }

    FinOps = {
      description      = "Cost, budgets, CUR, Athena access; no IAM or KMS decrypt"
      session_duration = "PT4H"
      managed_policies = []
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "FinOpsCostAccess"
            Effect = "Allow"
            Action = [
              "ce:*",
              "budgets:*",
              "cur:*",
              "aws-portal:View*",
              "athena:*",
              "glue:Get*",
              "s3:GetObject",
              "s3:ListBucket",
            ]
            Resource = "*"
          },
          {
            Sid    = "FinOpsDenyIamKms"
            Effect = "Deny"
            Action = [
              "iam:*",
              "kms:Decrypt",
            ]
            Resource = "*"
          },
        ]
      })
      boundary_policy = null
    }

    AppReadOnly = {
      description      = "AWS ReadOnlyAccess with explicit deny on secrets/KMS/IAM mutation"
      session_duration = "PT12H"
      managed_policies = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid    = "DenySensitive"
            Effect = "Deny"
            Action = [
              "secretsmanager:GetSecretValue",
              "kms:Decrypt",
              "iam:*",
            ]
            Resource = "*"
          },
        ]
      })
      boundary_policy = null
    }
  }

  groups = {
    platform-admins = { description = "Platform administrators with full access" }
    developers      = { description = "Development team members" }
    readonly        = { description = "Read-only stakeholders and auditors" }
    security-team   = { description = "Security team members" }
    tenant-admins   = { description = "Tenant-scoped administrators (PlatformId-bounded)" }
    auditors        = { description = "Read-only auditors" }
    finops          = { description = "Cost and budget operators" }
  }

  account_assignments = []
}
