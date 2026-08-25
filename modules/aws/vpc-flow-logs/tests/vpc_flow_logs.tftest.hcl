# Unit tests for the vpc-flow-logs module — the flow-log destination and the
# delivery role both VPC-owning components attach.
#
# Flow logs are the record of what talked to what inside the VPC, which makes them
# the evidence an incident is reconstructed from. Two things decide whether that
# evidence exists and stays trustworthy:
#
#   1. The delivery role is assumable ONLY by vpc-flow-logs.amazonaws.com. A
#      widened trust makes the log group writable by something other than the
#      flow-log service, which is the one thing that would let the record be
#      forged rather than merely lost.
#   2. Retention is set. A CloudWatch log group with no retention_in_days keeps
#      every event forever and bills for it forever — and the absence looks
#      identical to a deliberate choice.
#
# Plus the property that makes the module worth having: it captures ALL traffic by
# default rather than only rejects, because a reconstruction needs the accepted
# connections as much as the refused ones.

mock_provider "aws" {}

variables {
  vpc_id         = "vpc-0mock"
  log_group_name = "/aws/vpc/development-flow-logs"
  role_name      = "development-vpc-flow-logs"
}

run "delivery_role_is_assumable_only_by_the_flow_log_service" {
  command = plan

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role.this.assume_role_policy).Statement :
      s if try(s.Effect, "") == "Allow"
      && try(s.Principal.Service, "") == "vpc-flow-logs.amazonaws.com"
      && try(s.Action, "") == "sts:AssumeRole"
    ]) == 1
    error_message = "the flow-log delivery role must trust exactly vpc-flow-logs.amazonaws.com — a wider trust lets something other than the flow-log service write the record an incident is reconstructed from"
  }

  assert {
    condition     = length(jsondecode(aws_iam_role.this.assume_role_policy).Statement) == 1
    error_message = "the delivery role's trust must carry exactly one statement"
  }
}

run "delivery_grant_is_log_writes_only" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.this.policy).Statement : [
        for a in(can(tolist(s.Action)) ? tolist(s.Action) : [s.Action]) :
        startswith(a, "logs:")
      ]
    ]))
    error_message = "the delivery role may hold logs: actions and nothing else — it exists to write flow records, and any other service verb is scope it does not need"
  }
}

# Retention is asserted as a positive number rather than merely present: 0 is a
# valid CloudWatch value meaning never expire, so `!= null` would accept the
# forever case this exists to prevent.
run "log_group_expires" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_group.this.retention_in_days > 0
    error_message = "the flow-log group must set a positive retention_in_days — unset (or 0) keeps every flow record forever and bills for it forever, and the absence is indistinguishable from a deliberate choice"
  }
}

# ALL rather than REJECT. A reconstruction needs the connections that succeeded as
# much as the ones that were refused, and the narrower setting is the one someone
# reaches for to cut cost without noticing what it costs later.
run "captures_all_traffic_by_default" {
  command = plan

  assert {
    condition     = aws_flow_log.this.traffic_type == "ALL"
    error_message = "flow logs must capture ALL traffic by default — REJECT-only records what was refused and loses the accepted connections an incident is reconstructed from"
  }

  assert {
    condition     = aws_flow_log.this.vpc_id == "vpc-0mock"
    error_message = "the flow log must attach to the VPC the module was given"
  }
}
