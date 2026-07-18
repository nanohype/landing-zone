# vpc-flow-logs — the VPC flow-log wiring every network component shares.
#
# A VPC flow log needs three collaborating resources: the CloudWatch log group it
# writes to, an IAM role the flow-log service assumes to write there, and the flow
# log itself pointing at both. The create-mode `network` component, the
# `shared-network` owner, and the `egress-network` hub each need the identical set
# — so it lives here once, defined a single way, instead of drifting across three
# byte-for-byte copies.
#
# Instantiation is caller-gated: each component sets `count` on the module block
# (create-mode + enable_flow_logs for `network`; enable_flow_logs alone for the two
# always-owned VPCs), so the module carries no `enabled` flag of its own. The log
# group name and role name are passed in explicitly because they are not derivable
# from one another (e.g. the shared VPC logs to `<env>-shared` but names its role
# `<env>-shared-net-flow-logs`).

resource "aws_flow_log" "this" {
  iam_role_arn    = aws_iam_role.this.arn
  log_destination = aws_cloudwatch_log_group.this.arn
  traffic_type    = var.traffic_type
  vpc_id          = var.vpc_id

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = var.log_group_name
  retention_in_days = var.retention_in_days

  tags = var.tags
}

resource "aws_iam_role" "this" {
  name = var.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "this" {
  name = var.role_name
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "*"
    }]
  })
}
