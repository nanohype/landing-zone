# Who may assume the operator role. The operator mints tenant, session and
# scheduler-invoke roles, so its trust decides who holds that power: it must be
# exactly the eks-agent-platform/operator ServiceAccount, through the cluster's
# OIDC provider, for the STS audience. A wildcard sub, a second statement or a
# second principal would let another pod's token assume the role factory.
#
# agent_iam.tftest.hcl cannot assert this: its mock provider turns the trust's
# aws_iam_policy_document into a placeholder, so that file feeds a stub. This
# file runs a real provider with no credentials and every skip_* flag set, so
# the policy document renders locally and for real, and overrides only the two
# data sources that would call AWS. Nothing here reaches the network.

provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/test"
    user_id    = "AIDTEST"
  }
}

override_data {
  target = data.aws_partition.current
  values = {
    partition          = "aws"
    dns_suffix         = "amazonaws.com"
    reverse_dns_prefix = "com.amazonaws"
  }
}

variables {
  environment       = "development"
  cluster_name      = "development-platform"
  region            = "us-east-1"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED"
  oidc_issuer       = "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED"
  data_kms_key_arn  = "arn:aws:kms:us-east-1:123456789012:key/EXAMPLE-DATA-CMK"
}

run "operator_trust_is_exactly_the_operator_service_account" {
  command = plan

  # One statement only: a second would widen the trust whatever the first says.
  assert {
    condition     = length(jsondecode(aws_iam_role.operator.assume_role_policy).Statement) == 1
    error_message = "the operator trust must hold exactly one statement"
  }

  # That statement allows web-identity assumption by the cluster's OIDC provider
  # alone, with the sub pinned to one exact ServiceAccount and the audience to
  # STS. Equality on the whole condition map rejects a wildcard sub, a StringLike
  # condition, a second value and a dropped audience alike.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.operator.assume_role_policy).Statement : s
      if s.Effect == "Allow"
      && flatten([s.Action]) == ["sts:AssumeRoleWithWebIdentity"]
      && s.Principal == { Federated = var.oidc_provider_arn }
      && s.Condition == {
        StringEquals = {
          "${var.oidc_issuer}:sub" = "system:serviceaccount:eks-agent-platform:operator"
          "${var.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    ]) == 1
    error_message = "the operator trust must Allow only sts:AssumeRoleWithWebIdentity from the cluster's OIDC provider, with StringEquals sub = system:serviceaccount:eks-agent-platform:operator and aud = sts.amazonaws.com, and no other condition"
  }
}
