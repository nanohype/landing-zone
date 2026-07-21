# Unit tests for cluster-addons Pod Identity — the platform addon identities.
# These runs pin the least-privilege shape of the two grants most prone to
# over-broadening:
#
#   1. AWS Load Balancer Controller — the mutating EC2/ELB verbs must carry the
#      upstream reference policy's elbv2.k8s.aws/cluster tag conditions, so the
#      controller can only delete/retag security groups, load balancers, target
#      groups, and listeners IT created — never arbitrary account resources. The
#      regression this bites: ec2:DeleteSecurityGroup or ec2:DeleteTags on "*"
#      with no tag condition.
#   2. Argo Events — SQS/SNS event-source access is ARN-scoped to this
#      account/region and narrowed to the receive/subscribe verbs. The regression:
#      sqs:* / sns:* on Resource=["*"] (account-wide admin over every queue/topic).
#
# Runs at command = plan against a mocked AWS provider. The inline policies
# are jsonencode()'d inside the workload-identity child module and surfaced through
# the *_policy_json outputs, so their content renders for real at plan time. The
# s3-bucket modules' data.aws_iam_policy_document is handed a valid empty JSON stub
# purely to unblock the plan (not asserted).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
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
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
}

variables {
  environment         = "development"
  region              = "us-west-2"
  cluster_name        = "development-platform"
  team                = "platform"
  argo_events_enabled = true
}

# ── ALB controller: the destructive EC2/ELB verbs are tag-conditioned ──
run "alb_mutating_verbs_are_tag_conditioned" {
  command = plan

  # ec2:DeleteSecurityGroup exists AND every statement that grants it carries the
  # elbv2.k8s.aws/cluster ResourceTag Null condition — so the controller can only
  # delete security groups it owns, never an arbitrary one.
  assert {
    condition = (
      length([
        for s in jsondecode(output.alb_controller_policy_json).Statement :
        s if contains(try(s.Action, []), "ec2:DeleteSecurityGroup")
      ]) >= 1
      && alltrue([
        for s in jsondecode(output.alb_controller_policy_json).Statement :
        try(s.Condition.Null["aws:ResourceTag/elbv2.k8s.aws/cluster"], "") == "false"
        if contains(try(s.Action, []), "ec2:DeleteSecurityGroup")
      ])
    )
    error_message = "every ec2:DeleteSecurityGroup grant must carry the Null aws:ResourceTag/elbv2.k8s.aws/cluster=false condition (never unconditioned on \"*\")"
  }

  # ec2:DeleteTags is only ever granted on cluster-tagged security groups.
  assert {
    condition = alltrue([
      for s in jsondecode(output.alb_controller_policy_json).Statement :
      try(s.Condition.Null["aws:ResourceTag/elbv2.k8s.aws/cluster"], "") == "false"
      if contains(try(s.Action, []), "ec2:DeleteTags")
    ])
    error_message = "every ec2:DeleteTags grant must be conditioned on the elbv2.k8s.aws/cluster resource tag"
  }

  # The destructive ELB verbs (DeleteLoadBalancer / DeleteTargetGroup) are
  # conditioned on the cluster resource tag too.
  assert {
    condition = alltrue([
      for s in jsondecode(output.alb_controller_policy_json).Statement :
      try(s.Condition.Null["aws:ResourceTag/elbv2.k8s.aws/cluster"], "") == "false"
      if contains(try(s.Action, []), "elasticloadbalancing:DeleteLoadBalancer")
    ])
    error_message = "elasticloadbalancing:DeleteLoadBalancer must be conditioned on the elbv2.k8s.aws/cluster resource tag"
  }

  # iam:CreateServiceLinkedRole is scoped to the ELB service — it can never mint an
  # SLR for any other service.
  assert {
    condition = length([
      for s in jsondecode(output.alb_controller_policy_json).Statement :
      s if contains(try(s.Action, []), "iam:CreateServiceLinkedRole")
      && try(s.Condition.StringEquals["iam:AWSServiceName"], "") == "elasticloadbalancing.amazonaws.com"
    ]) == 1
    error_message = "iam:CreateServiceLinkedRole must be conditioned to iam:AWSServiceName=elasticloadbalancing.amazonaws.com"
  }
}

# ── Argo Events: SQS/SNS scoped to this account/region, no wildcard admin ──
run "argo_events_sqs_sns_are_arn_scoped" {
  command = plan

  # No statement grants the sqs:* / sns:* admin wildcards.
  assert {
    condition = alltrue([
      for s in jsondecode(output.argo_events_policy_json).Statement :
      !contains(try(s.Action, []), "sqs:*") && !contains(try(s.Action, []), "sns:*")
    ])
    error_message = "argo-events must not grant sqs:* or sns:* (admin over every queue/topic)"
  }

  # The SQS receive grant is scoped to this account/region, never Resource=[\"*\"].
  assert {
    condition = anytrue([
      for s in jsondecode(output.argo_events_policy_json).Statement :
      contains(try(s.Action, []), "sqs:ReceiveMessage")
      && contains(tolist(s.Resource), "arn:aws:sqs:us-west-2:123456789012:*")
      && !contains(tolist(s.Resource), "*")
    ])
    error_message = "argo-events SQS grant must be scoped to arn:aws:sqs:<region>:<account>:*, never Resource=[\"*\"]"
  }

  # The SNS subscribe grant is likewise account/region-scoped.
  assert {
    condition = anytrue([
      for s in jsondecode(output.argo_events_policy_json).Statement :
      contains(try(s.Action, []), "sns:Subscribe")
      && contains(tolist(s.Resource), "arn:aws:sns:us-west-2:123456789012:*")
      && !contains(tolist(s.Resource), "*")
    ])
    error_message = "argo-events SNS grant must be scoped to arn:aws:sns:<region>:<account>:*, never Resource=[\"*\"]"
  }
}
