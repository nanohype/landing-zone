locals {
  prefix = "${var.environment}-${var.tenant_id}"

  # Group the flat datastore list into a per-kind map keyed by datastore name,
  # so each resource file's for_each is one kind's stores. Datastore names are
  # unique within a Platform (the CR keys them as a listType=map), so the map
  # keys never collide.
  relational_stores = { for d in var.datastores : d.name => d if d.kind == "relational" }
  key_value_stores  = { for d in var.datastores : d.name => d if d.kind == "keyValue" }
  object_stores     = { for d in var.datastores : d.name => d if d.kind == "objectStore" }
  queue_stores      = { for d in var.datastores : d.name => d if d.kind == "queue" }
  cache_stores      = { for d in var.datastores : d.name => d if d.kind == "cache" }
  stream_stores     = { for d in var.datastores : d.name => d if d.kind == "stream" }

  # Datastore tags carry the tenant identity plus the BackupPolicy selector the
  # central backup plan matches on. Security groups and subnet groups take the
  # tenant tags without BackupPolicy — they hold no data to protect.
  tenant_tags = merge(var.tags, { Tenant = var.tenant_id })
  data_tags   = merge(local.tenant_tags, { BackupPolicy = var.backup_policy })

  # DynamoDB requires an attribute definition for every key referenced by the
  # table or any of its indexes. Collect partition + sort + all GSI keys and
  # dedupe by name so the dynamic attribute blocks are unique.
  kv_attributes = {
    for name, d in local.key_value_stores : name => distinct(concat(
      [d.key_value.partition_key],
      d.key_value.sort_key == null ? [] : [d.key_value.sort_key],
      flatten([
        for g in d.key_value.global_secondary_indexes : concat(
          [g.partition_key],
          g.sort_key == null ? [] : [g.sort_key],
        )
      ]),
    ))
  }
}
