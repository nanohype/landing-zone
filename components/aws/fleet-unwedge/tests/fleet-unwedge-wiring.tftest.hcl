# Wiring assertions for fleet-unwedge — the two facts that are ARN equalities.
#
# Split from fleet-unwedge.tftest.hcl on provider strategy, not on subject. That
# file runs a REAL credential-less provider because the trust is rendered by
# data.aws_iam_policy_document and a mock would replace it with a placeholder. But
# under a real provider an aws_iam_policy or aws_iam_role ARN is unknown at plan,
# so an equality against one is indeterminate — it neither passes nor fails for
# the reason you wanted.
#
# So these two live here, with a mock provider that pins those ARNs. Both are
# equalities that matter and neither is visible anywhere else:
#
#   * A boundary policy that exists but is not bound to the role is inert. It
#     reads as a ceiling in every review and constrains nothing at runtime, which
#     is the exact shape this repo has found in other components.
#   * The published SSM parameter is how portal FINDS this role. If it names
#     something other than the role this component created, the force-unwedge
#     action assumes a principal nobody audited — and the parameter reading as
#     present is what makes that invisible.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "222222222222"
      arn        = "arn:aws:iam::222222222222:user/test"
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
  # Pinned so the two equalities below compare known values. A random mock string
  # would also fail the provider's own ARN validation on permissions_boundary.
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::222222222222:policy/eks-fleet/staging-eks-fleet-unwedge-boundary"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::222222222222:role/eks-fleet/staging-eks-fleet-unwedge"
    }
  }
}

variables {
  environment     = "staging"
  region          = "us-east-1"
  team            = "platform"
  portal_role_arn = "arn:aws:iam::111111111111:role/portal-worker"
}

run "boundary_is_attached_and_the_published_arn_names_this_role" {
  command = plan

  assert {
    condition     = aws_iam_role.unwedge.permissions_boundary == aws_iam_policy.unwedge_boundary.arn
    error_message = "the unwedge role's permissions_boundary must be the boundary policy this component creates — an authored-but-unattached boundary reads as a ceiling and constrains nothing"
  }

  assert {
    condition     = aws_ssm_parameter.unwedge_role_arn.value == aws_iam_role.unwedge.arn
    error_message = "the published unwedge_role_arn must be this component's role ARN — portal assumes whatever this parameter names"
  }
}
