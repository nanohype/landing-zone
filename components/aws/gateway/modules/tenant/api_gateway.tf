locals {
  prefix      = "${var.environment}-gateway-${var.tenant_id}"
  namespace   = "gateway-${var.tenant_id}"
  tenant_tags = merge(var.tags, { Tenant = var.tenant_id })
}

resource "aws_api_gateway_rest_api" "this" {
  name        = local.prefix
  description = "API Gateway for tenant ${var.tenant_id}"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.tenant_tags
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.tenant_config.stage_name

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      caller         = "$context.identity.caller"
      user           = "$context.identity.user"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }

  tags = local.tenant_tags
}

resource "aws_api_gateway_method_settings" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    logging_level      = var.tenant_config.logging_level
    metrics_enabled    = true
    data_trace_enabled = var.environment == "development"
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.prefix}"
  retention_in_days = 30

  tags = local.tenant_tags
}
