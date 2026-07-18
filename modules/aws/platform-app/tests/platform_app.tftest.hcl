# Unit tests for the platform-app module — the shared Pod Identity + app-access
# shell every single-tenant `<app>-platform` component binds through. Runs at
# `command = plan` against a mocked AWS provider (no account, no network), so it
# gates the module's contract:
#
#   env-first grammar   — the app-access managed policy is <environment>-<app>-app-access
#                         under /eks-agent-platform/, never inverted.
#   faithful wrapping    — the app's substrate statements are wrapped verbatim into
#                         the managed policy (the module must not broaden scope).
#   association binding  — the Pod Identity association binds the exact
#                         (cluster, namespace, service_account) it was handed.
#   no-doubled-env       — an app_name equal to or prefixed with the environment
#                         token is rejected at variable validation, before it
#                         composes into a doubled "<env>-<env>-..." name.

mock_provider "aws" {
  # data.aws_iam_role.tenant is resolved by name; the association ARN-validates its
  # role_arn at plan, so hand the lookup a real ARN (the mock's random default isn't
  # ARN-shaped).
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/development-incident-response-tenant"
    }
  }
}

variables {
  app_name        = "incident-response"
  environment     = "development"
  cluster_name    = "development-platform"
  namespace       = "tenants-incident-response"
  service_account = "incident-response"
  policy_statements = [{
    Effect   = "Allow"
    Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    Resource = ["arn:aws:dynamodb:us-west-2:123456789012:table/development-incident-response-incidents"]
  }]
}

# ── env-first grammar + faithful wrapping ──
run "app_access_policy_is_env_first_and_faithful" {
  command = plan

  assert {
    condition     = aws_iam_policy.app_access.name == "development-incident-response-app-access"
    error_message = "the app-access managed policy must be named <environment>-<app_name>-app-access (env-first)"
  }
  assert {
    condition     = aws_iam_policy.app_access.path == "/eks-agent-platform/"
    error_message = "the app-access managed policy must live under /eks-agent-platform/"
  }
  assert {
    condition     = jsondecode(aws_iam_policy.app_access.policy).Statement[0].Action[0] == "dynamodb:GetItem"
    error_message = "the module must wrap the app's substrate statements verbatim (no broadening)"
  }
  assert {
    condition     = jsondecode(aws_iam_policy.app_access.policy).Statement[0].Resource[0] == "arn:aws:dynamodb:us-west-2:123456789012:table/development-incident-response-incidents"
    error_message = "the wrapped statement's Resource must pass through unchanged"
  }
}

# ── the Pod Identity association binds the exact identity it was handed ──
run "association_binds_exact_identity" {
  command = plan

  assert {
    condition     = aws_eks_pod_identity_association.app.cluster_name == "development-platform"
    error_message = "association must target the provided cluster_name"
  }
  assert {
    condition     = aws_eks_pod_identity_association.app.namespace == "tenants-incident-response"
    error_message = "association must target the provided namespace"
  }
  assert {
    condition     = aws_eks_pod_identity_association.app.service_account == "incident-response"
    error_message = "association must target the provided service_account"
  }
}

# ── no-doubled-env: app_name equal to the environment token is rejected ──
run "rejects_app_name_equal_to_env" {
  command = plan

  variables {
    app_name = "development"
  }

  expect_failures = [
    var.environment,
  ]
}

# ── no-doubled-env: app_name prefixed with the environment token is rejected ──
run "rejects_app_name_prefixed_with_env" {
  command = plan

  variables {
    app_name = "development-incident-response"
  }

  expect_failures = [
    var.environment,
  ]
}
