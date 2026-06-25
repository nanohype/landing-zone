module "gateway_admin_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-gateway-admin"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "gateway-admin"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "apigateway:GET",
        "apigateway:POST",
        "apigateway:PUT",
        "apigateway:PATCH",
      ]
      Resource = [
        aws_api_gateway_rest_api.this.arn,
        "${aws_api_gateway_rest_api.this.arn}/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminSetUserPassword",
        "cognito-idp:AdminGetUser",
        "cognito-idp:ListUsers",
      ]
      Resource = var.tenant_config.cognito_enabled ? [aws_cognito_user_pool.this[0].arn] : ["*"]
    },
    {
      Effect = "Allow"
      Action = [
        "wafv2:GetWebACL",
        "wafv2:UpdateWebACL",
      ]
      Resource = var.tenant_config.waf_enabled ? [aws_wafv2_web_acl.this[0].arn] : ["*"]
    },
    {
      Effect = "Allow"
      Action = [
        "cloudwatch:PutMetricData",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = ["*"]
    },
  ]

  tags = local.tenant_tags
}

module "gateway_auth_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-gateway-auth"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "gateway-auth"

  policy_statements = [
    {
      Effect = "Allow"
      Action = [
        "cognito-idp:GetUser",
        "cognito-idp:InitiateAuth",
        "cognito-idp:RespondToAuthChallenge",
      ]
      Resource = var.tenant_config.cognito_enabled ? [aws_cognito_user_pool.this[0].arn] : ["*"]
    },
    {
      Effect = "Allow"
      Action = [
        "apigateway:GET",
      ]
      Resource = [
        aws_api_gateway_rest_api.this.arn,
        "${aws_api_gateway_rest_api.this.arn}/*",
      ]
    },
    {
      Effect = "Allow"
      Action = [
        "cloudwatch:PutMetricData",
      ]
      Resource = ["*"]
    },
  ]

  tags = local.tenant_tags
}
