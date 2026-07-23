################################################################################
# keyValue -> DynamoDB
################################################################################

resource "aws_dynamodb_table" "key_value" {
  #checkov:skip=CKV2_AWS_16:the table defaults to PAY_PER_REQUEST, which needs no autoscaling; billing mode is tenant-configurable and checkov cannot resolve the per-tenant value to confirm it
  for_each = local.key_value_stores

  name         = "${local.prefix}-${each.key}"
  billing_mode = each.value.key_value.billing_mode
  hash_key     = each.value.key_value.partition_key.name
  range_key    = try(each.value.key_value.sort_key.name, null)

  # One attribute definition per key referenced by the table or any index,
  # deduped by name in locals.
  dynamic "attribute" {
    for_each = { for a in local.kv_attributes[each.key] : a.name => a }
    content {
      name = attribute.value.name
      type = attribute.value.type
    }
  }

  dynamic "global_secondary_index" {
    for_each = { for g in each.value.key_value.global_secondary_indexes : g.name => g }
    content {
      name            = global_secondary_index.value.name
      hash_key        = global_secondary_index.value.partition_key.name
      range_key       = try(global_secondary_index.value.sort_key.name, null)
      projection_type = global_secondary_index.value.projection
    }
  }

  dynamic "ttl" {
    for_each = each.value.key_value.ttl_attribute == null ? [] : [each.value.key_value.ttl_attribute]
    content {
      attribute_name = ttl.value
      enabled        = true
    }
  }

  point_in_time_recovery {
    enabled = each.value.key_value.point_in_time_recovery
  }

  # A Retain datastore also gets the AWS-level backstop, so an accidental
  # destroy is blocked until the protection is explicitly cleared.
  deletion_protection_enabled = each.value.deletion_policy == "Retain"

  tags = local.data_tags
}
