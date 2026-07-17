locals {
  prefix    = "${var.environment}-rag-${var.tenant_id}"
  namespace = "rag-${var.tenant_id}"
  # Account-qualified so S3 bucket names are globally unique (S3's namespace is
  # global). The component's `tenants` variable validation asserts the composed
  # length fits 63.
  bucket_prefix = "${local.prefix}-${var.account_id}"
  tenant_tags   = merge(var.tags, { Tenant = var.tenant_id })
}

resource "aws_opensearchserverless_security_policy" "encryption" {
  name = "${local.prefix}-enc"
  type = "encryption"

  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.prefix}-vectors"]
    }]
    AWSOwnedKey = true
  })
}

resource "aws_opensearchserverless_security_policy" "network" {
  name = "${local.prefix}-net"
  type = "network"

  policy = jsonencode([{
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/${local.prefix}-vectors"]
    }]
    AllowFromPublic = true
  }])
}

resource "aws_opensearchserverless_collection" "vectors" {
  name             = "${local.prefix}-vectors"
  type             = "VECTORSEARCH"
  standby_replicas = var.tenant_config.opensearch_standby_replicas ? "ENABLED" : "DISABLED"

  depends_on = [
    aws_opensearchserverless_security_policy.encryption,
    aws_opensearchserverless_security_policy.network,
  ]

  tags = local.tenant_tags
}

resource "aws_opensearchserverless_access_policy" "data" {
  name = "${local.prefix}-data"
  type = "data"

  policy = jsonencode([{
    Rules = [
      {
        ResourceType = "index"
        Resource     = ["index/${local.prefix}-vectors/*"]
        Permission   = ["aoss:CreateIndex", "aoss:UpdateIndex", "aoss:DescribeIndex", "aoss:ReadDocument", "aoss:WriteDocument"]
      },
      {
        ResourceType = "collection"
        Resource     = ["collection/${local.prefix}-vectors"]
        Permission   = ["aoss:CreateCollectionItems", "aoss:UpdateCollectionItems", "aoss:DescribeCollectionItems"]
      },
    ]
    Principal = [module.bedrock_api_irsa.iam_role_arn]
  }])
}
