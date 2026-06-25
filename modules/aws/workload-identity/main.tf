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

resource "aws_iam_role_policy" "this" {
  count = length(var.policy_statements) > 0 ? 1 : 0
  name  = "${var.role_name}-policy"
  role  = aws_iam_role.this.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = var.policy_statements
  })
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}
