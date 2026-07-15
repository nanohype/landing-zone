# Unit tests for the workload-identity module — the Pod Identity role factory every
# tenant/operator role is minted through. These run at `command = plan` with dummy
# credentials (no AWS calls), so they gate the module's security contract in CI
# without needing a live account.

provider "aws" {
  region                      = "us-west-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

variables {
  role_name       = "dev-example-tenant"
  cluster_name    = "dev-eks"
  namespace       = "example"
  service_account = "example-sa"
}

# The load-bearing invariant: the trust policy is Pod-Identity-only. A stray
# OIDC/web-identity principal (the IRSA shape) would let a role-arn annotation
# assume this role off-cluster — exactly what Pod Identity is chosen to avoid.
run "trust_policy_is_pod_identity_only" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com"
    error_message = "trust principal must be pods.eks.amazonaws.com (Pod Identity), not an OIDC/web-identity provider"
  }

  assert {
    condition     = toset(jsondecode(aws_iam_role.this.assume_role_policy).Statement[0].Action) == toset(["sts:AssumeRole", "sts:TagSession"])
    error_message = "trust policy must grant exactly sts:AssumeRole + sts:TagSession"
  }

  # No AssumeRoleWithWebIdentity anywhere in the trust policy.
  assert {
    condition     = !strcontains(aws_iam_role.this.assume_role_policy, "WebIdentity")
    error_message = "trust policy must not contain any web-identity (IRSA) assume action"
  }
}

# The association must bind the exact (cluster, namespace, service_account) it was
# given — a mismatch would silently hand credentials to the wrong workload.
run "association_binds_exact_identity" {
  command = plan

  assert {
    condition     = aws_eks_pod_identity_association.this.cluster_name == "dev-eks"
    error_message = "association must target the provided cluster_name"
  }
  assert {
    condition     = aws_eks_pod_identity_association.this.namespace == "example"
    error_message = "association must target the provided namespace"
  }
  assert {
    condition     = aws_eks_pod_identity_association.this.service_account == "example-sa"
    error_message = "association must target the provided service_account"
  }
}

# path + permissions_boundary flow through unchanged. Cross-account fleet-vend
# gating depends on the role landing under the requested path (e.g. /eks-fleet/),
# and the boundary is what caps a tenant role's blast radius.
run "path_and_boundary_flow_through" {
  command = plan

  variables {
    path                 = "/eks-fleet/"
    permissions_boundary = "arn:aws:iam::123456789012:policy/tenant-boundary"
  }

  assert {
    condition     = aws_iam_role.this.path == "/eks-fleet/"
    error_message = "role path must equal the provided var.path"
  }
  assert {
    condition     = aws_iam_role.this.permissions_boundary == "arn:aws:iam::123456789012:policy/tenant-boundary"
    error_message = "role must carry the provided permissions_boundary"
  }
}

# The default path is AWS root and there is no boundary — documenting the
# same-account default so a regression that silently injects one is caught.
run "defaults_are_root_path_no_boundary" {
  command = plan

  assert {
    condition     = aws_iam_role.this.path == "/"
    error_message = "default path must be \"/\""
  }
  assert {
    condition     = aws_iam_role.this.permissions_boundary == null
    error_message = "default permissions_boundary must be null (no boundary)"
  }
}

# The inline policy is a faithful pass-through of policy_statements — the module
# must not broaden scope. Also asserts the statement is created only when
# statements are supplied.
run "inline_policy_is_faithful_passthrough" {
  command = plan

  variables {
    policy_statements = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["arn:aws:s3:::dev-example-bucket/*"]
    }]
  }

  assert {
    condition     = length(aws_iam_role_policy.this) == 1
    error_message = "inline policy resource must exist when policy_statements is non-empty"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.this[0].policy).Statement[0].Resource[0] == "arn:aws:s3:::dev-example-bucket/*"
    error_message = "inline policy must pass the provided Resource through unchanged (no broadening to *)"
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.this[0].policy).Statement[0].Action[0] == "s3:GetObject"
    error_message = "inline policy must pass the provided Action through unchanged"
  }
}

# With no policy_statements (the default), the inline policy resource is not
# created at all — a role with no inline grants until one is explicitly attached.
run "no_inline_policy_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.this) == 0
    error_message = "inline policy resource must not be created when policy_statements is empty"
  }
}
