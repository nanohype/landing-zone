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

    # Tenant-facing human SSO personas (distinct from the per-tenant Pod Identity
    # roles the eks-agent-platform operator mints). Scoped on the tenant tag key
    # PlatformId, which is the only tenant-identity tag this org recognizes.
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
            # Reading a KMS-encrypted log group needs kms:Decrypt on the key
            # CloudWatch Logs encrypted it with. Without this, every
            # logs:GetLogEvents above returns AccessDenied on every encrypted
            # group — which is every group this platform creates — so the
            # auditor's whole read surface was arranged and never usable.
            #
            # Scoped by ALIAS, not key ARN: the key lives in a workload account
            # this component cannot read at plan time, and the alias is what
            # carries the meaning. `<environment>-platform-logs` exists only
            # where that environment set separate_logs_key on its secrets
            # component.
            #
            # Mode-independence is the point, and it is why there is no branch
            # here. Where logs and data share one key that key is aliased
            # `<environment>-platform-secrets`, so this statement matches
            # nothing and the auditor gets no decrypt at all — which is correct,
            # because decrypt on that key IS decrypt on platform data. The
            # auditor gains the ability to read logs exactly when, and only
            # where, reading logs stops implying reading data.
            Sid      = "AuditorReadSeparatedLogKeys"
            Effect   = "Allow"
            Action   = ["kms:Decrypt", "kms:DescribeKey"]
            Resource = "arn:aws:kms:*:*:key/*"
            Condition = {
              "ForAnyValue:StringLike" = {
                "kms:ResourceAliases" = "alias/*-platform-logs"
              }
            }
          },
          {
            # Belt to the braces above. The Allow is already narrow, but an
            # explicit Deny cannot be overridden by any Allow, so this holds
            # even if someone later attaches a managed policy or widens a
            # statement: the auditor may never use the key platform data is
            # encrypted with.
            #
            # Consequence worth knowing rather than discovering: Athena results
            # and the cost buckets are encrypted with that same data key, so the
            # `athena:*` grant above can run a query and not read its output.
            # Auditing spend is FinOps's job, and FinOpsDenyIamKms puts that
            # permission set under the same constraint.
            Sid    = "AuditorDenyDataKey"
            Effect = "Deny"
            Action = [
              "kms:Decrypt",
              "kms:GenerateDataKey*",
              "kms:ReEncrypt*",
            ]
            Resource = "arn:aws:kms:*:*:key/*"
            Condition = {
              "ForAnyValue:StringLike" = {
                "kms:ResourceAliases" = "alias/*-platform-secrets"
              }
            }
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
