resource "aws_iam_role" "this" {
  name                 = var.role_name
  path                 = var.path
  permissions_boundary = var.permissions_boundary

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession",
      ]
    }]
  })

  tags = var.tags
}

# Binds the (namespace, service_account) pair to this role through the EKS API.
# EKS injects credentials into pods using the service account; no role-arn
# annotation and no OIDC provider are involved.
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn

  tags = var.tags
}

locals {
  # Condition is an optional attribute. Drop the key entirely when a statement
  # doesn't set one so the rendered policy never carries "Condition": null (which
  # IAM rejects). Statements that DO set a Condition pass it through verbatim, so
  # a caller's tag/ARN/StringEquals condition reaches the role unbroadened.
  rendered_statements = [
    for s in var.policy_statements : merge(
      {
        Effect   = s.Effect
        Action   = s.Action
        Resource = s.Resource
      },
      s.Condition == null ? {} : { Condition = s.Condition },
    )
  ]
}

resource "aws_iam_role_policy" "this" {
  count = length(var.policy_statements) > 0 ? 1 : 0
  name  = "${var.role_name}-policy"
  role  = aws_iam_role.this.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.rendered_statements
  })
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}
