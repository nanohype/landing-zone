locals {
  prefix = "${var.environment}-${var.tenant_id}"

  # Teardown posture: development always allows a full destroy; elsewhere it is
  # opt-in via force_destroy_buckets (same two-act contract as agent-iam / druid).
  # Without skip_final_snapshot=true OR a final_snapshot_identifier the provider
  # refuses Aurora destroy; without force_destroy a versioned objectStore refuses
  # S3 destroy. Both halves of the wedge land here.
  allow_teardown = var.environment == "development" || var.force_destroy_buckets

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
  #
  # PlatformId is the org's tenant-identity tag: the operator stamps it on the
  # tenant IAM role, org-identity's ABAC is written against it, and the
  # BudgetPolicy reconciler groups Cost Explorer by it. These datastores are the
  # per-tenant spend — an IAM role bills nothing — so without it here the whole
  # attribution chain terminates at a tag no billed resource carries.
  #
  # The key is `PlatformId` exactly. Cost Explorer treats tag keys as
  # case-sensitive and CUR renders this one as `resource_tags_user_platformid`,
  # so the lowercase form reads like the name to activate and activates nothing.
  #
  # The value is the Platform name, which is also what composes local.prefix —
  # the same `<env>-<platform>-<datastore>` convention the operator's
  # datastore-access policy scopes its ARNs to. One value, one meaning.
  #
  # Team, not Tenant, carries the owning team: it arrives in var.tags from the
  # component. `Tenant` is deliberately not set here — the operator uses that
  # key for `Platform.spec.tenant`, the team, so setting it to the platform name
  # would put two meanings behind one key on resources belonging to one tenant.
  tenant_tags = merge(var.tags, { PlatformId = var.tenant_id })
  data_tags   = merge(local.tenant_tags, { BackupPolicy = var.backup_policy })

  # The BackupPolicy tag is a claim, and it is only true for resource types AWS
  # Backup can actually protect. Aurora, DynamoDB and S3 are on the supported-
  # resource list; SQS, ElastiCache and MSK are not
  # (docs.aws.amazon.com/aws-backup/latest/devguide/backup-feature-availability.html).
  #
  # Tagging an unsupported kind fails silently rather than loudly: the plan's tag
  # selector simply never matches, so the resource sits there carrying a tag that
  # reads "protected daily" while nothing ever backs it up. That is the same
  # failure the object-store versioning gate below exists to prevent, applied to
  # the kinds where the answer is categorical rather than per-datastore.
  #
  # What each ineligible kind's durability actually is:
  #
  #   queue  — SQS replicates every message across AZs itself and there is no
  #            snapshot to restore from. The only durability knob is
  #            queue.message_retention_seconds (default 4 days).
  #   cache  — derived data, rebuilt from its source of record. Deliberately
  #            unprotected, and ElastiCache's own snapshot_retention_limit is
  #            left at the provider default of 0 for the same reason: a cache
  #            that needs restoring is a database with the wrong kind declared.
  #   stream — MSK Serverless durability is the managed replication the service
  #            performs plus per-topic retention, which producers set through the
  #            Kafka admin API rather than here. Neither is a restorable snapshot.
  #
  # Keyed by kind so adding a datastore kind cannot silently inherit a claim:
  # the new resource file has to name its key, and a missing one fails at plan.
  datastore_tags = {
    relational = local.data_tags
    keyValue   = local.data_tags
    # objectStore resolves per-datastore through object_store_tags below —
    # eligible, but only once versioning is on.
    objectStore = local.data_tags
    queue       = local.tenant_tags
    cache       = local.tenant_tags
    stream      = local.tenant_tags
  }

  # S3 is the one datastore kind where the BackupPolicy tag is not sufficient on its own.
  # AWS Backup requires S3 Versioning on the bucket
  # (docs.aws.amazon.com/aws-backup/latest/devguide/s3-backups.html), and an object store's
  # versioning is a per-datastore choice that may be Suspended. A tagged, unversioned bucket
  # is selected by the central plan and then fails every backup job, which reads as covered
  # while being unprotected — so the tag is withheld instead, and the bucket carries the
  # tenant tags alone. Suspending versioning on an object store therefore opts it out of
  # central backup, deliberately and visibly.
  object_store_tags = {
    for name, d in local.object_stores : name => (
      d.object_store.versioning ? local.datastore_tags["objectStore"] : local.tenant_tags
    )
  }

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
