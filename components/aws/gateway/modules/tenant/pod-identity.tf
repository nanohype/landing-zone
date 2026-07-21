module "gateway_admin_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-gateway-admin"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "gateway-admin"

  # Feature-gated statements are OMITTED ENTIRELY when the feature is off — the
  # same pattern the llm/mlops tenant modules use — rather than falling back to
  # Resource=["*"]. A disabled cognito/waf feature must grant zero access to those
  # services, never account-wide access to every user pool / web ACL.
  policy_statements = concat(
    [
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
    ],
    var.tenant_config.cognito_enabled ? [
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:AdminCreateUser",
          "cognito-idp:AdminSetUserPassword",
          "cognito-idp:AdminGetUser",
          "cognito-idp:ListUsers",
        ]
        Resource = [aws_cognito_user_pool.this[0].arn]
      },
    ] : [],
    var.tenant_config.waf_enabled ? [
      {
        Effect = "Allow"
        Action = [
          "wafv2:GetWebACL",
          "wafv2:UpdateWebACL",
        ]
        Resource = [aws_wafv2_web_acl.this[0].arn]
      },
    ] : [],
    [
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
    ],
  )

  tags = local.tenant_tags
}

module "gateway_auth_irsa" {
  source = "../../../../../modules/aws/workload-identity"

  role_name       = "${local.prefix}-gateway-auth"
  cluster_name    = var.cluster_name
  namespace       = local.namespace
  service_account = "gateway-auth"

  # The cognito auth grant is omitted entirely when cognito is disabled (no
  # Resource=["*"] fallback); the apigateway + cloudwatch grants always apply.
  policy_statements = concat(
    var.tenant_config.cognito_enabled ? [
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:GetUser",
          "cognito-idp:InitiateAuth",
          "cognito-idp:RespondToAuthChallenge",
        ]
        Resource = [aws_cognito_user_pool.this[0].arn]
      },
    ] : [],
    [
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
    ],
  )

  tags = local.tenant_tags
}
