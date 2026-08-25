# The boundary attachment for portal-spoke.
#
# Split from portal-spoke.tftest.hcl on provider strategy rather than subject:
# that file needs a REAL provider so the trust's policy document renders, and
# under a real provider an aws_iam_policy ARN is unknown at plan — an equality
# against it is indeterminate rather than true. Here the ARN is pinned by a mock,
# so the equality compares known values and means what it says.
#
# The fact itself is worth its own file: a boundary policy that exists but is not
# bound to the role reads as a ceiling in every review and constrains nothing at
# runtime.

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
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::222222222222:policy/staging-portal-spoke-boundary"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::222222222222:role/staging-portal-spoke"
    }
  }
}

variables {
  environment         = "staging"
  team                = "platform"
  portal_hub_role_arn = "arn:aws:iam::111111111111:role/portal-hub"
}

run "boundary_is_attached_and_the_published_arn_names_this_role" {
  command = plan

  assert {
    condition     = aws_iam_role.spoke.permissions_boundary == aws_iam_policy.spoke_boundary.arn
    error_message = "the spoke role's permissions_boundary must be the boundary policy this component creates — an authored-but-unattached boundary constrains nothing"
  }

  assert {
    condition     = aws_ssm_parameter.spoke_role_arn.value == aws_iam_role.spoke.arn
    error_message = "the published spoke_role_arn must be this component's role ARN — the portal hub assumes whatever this parameter names"
  }
}
