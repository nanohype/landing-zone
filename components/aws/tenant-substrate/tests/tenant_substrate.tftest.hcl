# Unit tests for tenant-substrate — the generic per-tenant datastore substrate.
#
# Two contracts under test. (1) The variable-boundary name-length proof: a
# datastore name that would overflow a service's identifier limit — ElastiCache's
# 40-char replication_group_id, S3's 63-char bucket name — is rejected by the
# component's `tenants` validation before any resource is composed, and so is a
# tenant key that doubles the environment token or an unknown kind. (2) The
# BackupPolicy tag the central backup plan selects on lands on exactly the
# datastore kinds AWS Backup can protect and on none of the others, a
# redrive-configured queue gets its dead-letter queue, and every teardown gate
# moves on one lever — armed together in a protected environment, open together
# where a teardown is permitted.
#
# Runs at command = plan against a mocked AWS provider (no account, no network).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDTEST"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      name = "us-west-2"
    }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      # ElastiCache AUTH requires 16–128 alphanumeric (or limited symbols).
      result = "abcdefghijklmnopqrstuvwxyz012345"
    }
  }
}

# ── shared component-level inputs for the validation runs ──
variables {
  environment        = "development"
  region             = "us-west-2"
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  cluster_sg_id      = "sg-0123456789abcdef0"
  node_sg_id         = "sg-0fedcba9876543210"
  cluster_name       = "development-platform"
  team               = "platform"
  tenants            = {}
}

# ── cost attribution: PlatformId lands on every billed datastore ──
#
# The tag is the whole attribution chain. Cost Explorer and CUR are the only
# places per-tenant substrate spend can be read, both key on an activated cost
# allocation tag, and activation is not retroactive — so a kind that silently
# misses this tag is spend that can never be attributed after the fact, not
# spend that is attributed late.
#
# Asserted against `var.tenant_id` rather than a spelled-out "t1": a literal
# would keep passing if the module started tagging with the team, the
# environment, or a constant.
run "every_billed_datastore_carries_platform_id" {
  command = plan

  module {
    source = "./modules/tenant"
  }

  variables {
    environment     = "development"
    account_id      = "123456789012"
    tenant_id       = "t1"
    cluster_name    = "development-platform"
    vpc_id          = "vpc-0123456789abcdef0"
    private_subnets = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id   = "sg-0123456789abcdef0"
    node_sg_id      = "sg-0fedcba9876543210"
    backup_policy   = "daily"
    tags            = {}
    datastores = [
      { name = "kv", kind = "keyValue", key_value = { partition_key = { name = "pk", type = "S" } } },
      { name = "obj", kind = "objectStore" },
      { name = "q", kind = "queue" },
      { name = "ca", kind = "cache" },
      { name = "st", kind = "stream" },
    ]
  }

  assert {
    condition     = aws_dynamodb_table.key_value["kv"].tags["PlatformId"] == "${var.cluster_name}-${var.tenant_id}"
    error_message = "the DynamoDB table must carry PlatformId — without it its spend reaches no tenant in Cost Explorer or CUR"
  }
  assert {
    condition     = aws_s3_bucket.object_store["obj"].tags["PlatformId"] == "${var.cluster_name}-${var.tenant_id}"
    error_message = "the S3 bucket must carry PlatformId"
  }
  assert {
    condition     = aws_sqs_queue.queue["q"].tags["PlatformId"] == "${var.cluster_name}-${var.tenant_id}"
    error_message = "the SQS queue must carry PlatformId"
  }
  assert {
    condition     = aws_elasticache_replication_group.cache["ca"].tags["PlatformId"] == "${var.cluster_name}-${var.tenant_id}"
    error_message = "the ElastiCache replication group must carry PlatformId"
  }
  assert {
    condition     = aws_msk_serverless_cluster.stream["st"].tags["PlatformId"] == "${var.cluster_name}-${var.tenant_id}"
    error_message = "the MSK Serverless cluster must carry PlatformId"
  }

  # Case matters. Cost Explorer treats tag keys as case-sensitive and CUR
  # renders this one as resource_tags_user_platform_id, so the lowercase form
  # reads like the key to activate in Billing and would attribute nothing.
  assert {
    condition     = !contains(keys(aws_dynamodb_table.key_value["kv"].tags), "platformid")
    error_message = "the tag key must be PlatformId exactly — a lowercase key activates nothing in Billing"
  }

  # The value must not be the bare Platform name. A resource NAME only has to be
  # unique among resources and `<env>-<platform>-<datastore>` already is, but this
  # tag is read out of a CUR, and a CUR covers a whole ACCOUNT — every
  # environment's rows land in one table. Two co-located clusters may each host a
  # Platform called `t1` (the operator's tenant role is cluster-keyed for exactly
  # that reason), so a bare value is one attribution row standing for two tenants:
  # their spend sums, both BudgetPolicies read the pair's total as their own, and
  # at 120% the kill switch suspends whichever it was pointed at.
  assert {
    condition     = aws_dynamodb_table.key_value["kv"].tags["PlatformId"] != var.tenant_id
    error_message = "PlatformId is the bare Platform name — in an account-wide CUR that is one row for every same-named Platform in the account, so each tenant's budget reads the others' spend as its own"
  }

  # And it must be the CLUSTER, not the environment. Those differ: cluster_name is
  # `<environment>-<clusterBase>`, so an environment token alone still collides
  # between sibling clusters in one environment — which is the case the cluster
  # discriminator exists to cover (nanohype/standards/resource-naming.json,
  # cluster-scoped-substrate).
  assert {
    condition     = startswith(aws_dynamodb_table.key_value["kv"].tags["PlatformId"], "${var.cluster_name}-")
    error_message = "PlatformId must be qualified by the full cluster name, not by the environment — two clusters in one environment would otherwise share an attribution row"
  }

  # `Tenant` belongs to the operator, which sets it to Platform.spec.tenant —
  # the owning team. Setting it here to the platform name would put two
  # meanings behind one key across the two layers of one tenant's resources.
  # The team reaches these resources as the Team tag, from the component.
  assert {
    condition     = !contains(keys(aws_dynamodb_table.key_value["kv"].tags), "Tenant")
    error_message = "the module must not set Tenant — the operator uses that key for the owning team"
  }
}

# ── positive: one datastore of every kind provisions, tagged for backup ──
run "every_kind_provisions_and_is_backup_tagged" {
  command = plan

  module {
    source = "./modules/tenant"
  }

  variables {
    environment     = "development"
    account_id      = "123456789012"
    tenant_id       = "t1"
    cluster_name    = "development-platform"
    vpc_id          = "vpc-0123456789abcdef0"
    private_subnets = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id   = "sg-0123456789abcdef0"
    node_sg_id      = "sg-0fedcba9876543210"
    backup_policy   = "daily"
    tags            = {}
    datastores = [
      { name = "db", kind = "relational", relational = {} },
      { name = "kv", kind = "keyValue", key_value = { partition_key = { name = "pk", type = "S" } } },
      { name = "obj", kind = "objectStore" },
      { name = "q", kind = "queue", queue = { max_receive_count = 3 } },
      { name = "ca", kind = "cache" },
      { name = "st", kind = "stream" },
    ]
  }

  # BackupPolicy tag is stamped on the mintable datastores.
  assert {
    condition     = aws_dynamodb_table.key_value["kv"].tags["BackupPolicy"] == "daily"
    error_message = "the DynamoDB table must carry BackupPolicy=daily so the central backup plan selects it"
  }
  assert {
    condition     = aws_s3_bucket.object_store["obj"].tags["BackupPolicy"] == "daily"
    error_message = "the S3 bucket must carry BackupPolicy=daily"
  }
  # (Aurora is composed through the upstream rds-aurora module rather than a direct
  # aws_rds_cluster resource, so its tags are not addressable here.)

  # ...and withheld from the kinds AWS Backup cannot protect. SQS, ElastiCache and MSK are
  # absent from the supported-resource table, so the plan's tag selector never matches them:
  # the tag would not fail a job, it would silently select nothing while reading as
  # "protected daily" to anyone auditing the account.
  assert {
    condition     = !contains(keys(aws_sqs_queue.queue["q"].tags), "BackupPolicy")
    error_message = "an SQS queue must NOT carry BackupPolicy — AWS Backup does not support SQS, so the tag would claim protection nothing delivers"
  }
  assert {
    condition     = !contains(keys(aws_sqs_queue.dlq["q"].tags), "BackupPolicy")
    error_message = "a dead-letter queue must NOT carry BackupPolicy either — same unsupported resource type as the queue it drains"
  }
  assert {
    condition     = !contains(keys(aws_elasticache_replication_group.cache["ca"].tags), "BackupPolicy")
    error_message = "an ElastiCache replication group must NOT carry BackupPolicy — AWS Backup does not support ElastiCache, and a cache is rebuilt from its source of record"
  }
  assert {
    condition     = !contains(keys(aws_msk_serverless_cluster.stream["st"].tags), "BackupPolicy")
    error_message = "an MSK Serverless cluster must NOT carry BackupPolicy — AWS Backup does not support MSK; stream durability is managed replication plus per-topic retention"
  }

  # Withholding the backup claim must not cost the ineligible kinds their identity: the
  # tenant tags drive cost attribution and are unrelated to durability.
  assert {
    condition     = aws_elasticache_replication_group.cache["ca"].tags["PlatformId"] == "${var.cluster_name}-${var.tenant_id}"
    error_message = "withholding BackupPolicy must not drop the tenant tags"
  }

  # AUTH + transit encryption: SG membership alone must not be enough to read
  # a tenant's cache. The AUTH token is stored under the tenant CMK.
  assert {
    condition     = aws_elasticache_replication_group.cache["ca"].transit_encryption_enabled
    error_message = "cache must enable transit encryption"
  }
  assert {
    condition     = aws_elasticache_replication_group.cache["ca"].auth_token != null
    error_message = "cache must set an AUTH token — without it any principal on the cluster SG can read the cache over TLS"
  }
  assert {
    condition     = aws_secretsmanager_secret.cache_auth["ca"].kms_key_id == aws_kms_key.tenant.arn
    error_message = "cache AUTH secret must be encrypted with the tenant's own CMK"
  }

  # A permitted teardown opens every gate. This run is development, where teardown is
  # unconditional, so the Retain backstop is clear — the objectStore in this same module
  # already force-destroys under the same lever, and e2e tears this environment down on
  # every run. The protected direction is asserted in the run below.
  assert {
    condition     = aws_dynamodb_table.key_value["kv"].deletion_protection_enabled == false
    error_message = "a permitted teardown must clear the keyValue backstop, or the reverse sweep empties the object store and then wedges on the table"
  }

  # a redrive budget provisions the dead-letter queue and wires the redrive.
  assert {
    condition     = length(aws_sqs_queue.dlq) == 1
    error_message = "a queue with max_receive_count > 0 must get a dead-letter queue"
  }
  assert {
    condition     = aws_sqs_queue.queue["q"].redrive_policy != null
    error_message = "a queue with max_receive_count > 0 must set a redrive policy"
  }

  # the account-qualified bucket name is globally unique.
  assert {
    condition     = aws_s3_bucket.object_store["obj"].bucket == "development-t1-obj-123456789012"
    error_message = "the S3 bucket name must be account-qualified: <env>-<tenant>-<datastore>-<account>"
  }
}

# ── default policy leaves a queue without a DLQ ──
# ── an unversioned object store is NOT backup-tagged ──
#
# AWS Backup requires S3 Versioning on the bucket, so a BackupPolicy tag on an unversioned
# bucket is selected by the central plan and then fails every job — it reads as protected
# while being unprotected. Suspending versioning opts the datastore out of central backup,
# and the tag has to reflect that or it lies. Every other datastore kind is unaffected.
run "unversioned_object_store_is_not_backup_tagged" {
  command = plan

  module {
    source = "./modules/tenant"
  }

  variables {
    environment     = "development"
    account_id      = "123456789012"
    tenant_id       = "t1"
    cluster_name    = "development-platform"
    vpc_id          = "vpc-0123456789abcdef0"
    private_subnets = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id   = "sg-0123456789abcdef0"
    node_sg_id      = "sg-0fedcba9876543210"
    backup_policy   = "daily"
    tags            = {}
    datastores = [
      { name = "kept", kind = "objectStore", object_store = { versioning = true } },
      { name = "loose", kind = "objectStore", object_store = { versioning = false } },
      { name = "kv", kind = "keyValue", key_value = { partition_key = { name = "pk", type = "S" } } },
    ]
  }

  assert {
    condition     = aws_s3_bucket.object_store["kept"].tags["BackupPolicy"] == "daily"
    error_message = "a versioned object store must carry BackupPolicy so the central plan selects it"
  }
  assert {
    condition     = !contains(keys(aws_s3_bucket.object_store["loose"].tags), "BackupPolicy")
    error_message = "an unversioned object store must NOT carry BackupPolicy — AWS Backup requires S3 Versioning, so the tag would promise protection that cannot be delivered"
  }
  assert {
    condition     = aws_s3_bucket.object_store["loose"].tags["PlatformId"] == "${var.cluster_name}-${var.tenant_id}"
    error_message = "withholding BackupPolicy must not drop the tenant tags"
  }
  assert {
    condition     = aws_dynamodb_table.key_value["kv"].tags["BackupPolicy"] == "daily"
    error_message = "the versioning gate is S3-only; it must not withhold BackupPolicy from the other eligible kinds"
  }
}

run "queue_without_redrive_has_no_dlq" {
  command = plan

  module {
    source = "./modules/tenant"
  }

  variables {
    environment     = "development"
    account_id      = "123456789012"
    tenant_id       = "t1"
    cluster_name    = "development-platform"
    vpc_id          = "vpc-0123456789abcdef0"
    private_subnets = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id   = "sg-0123456789abcdef0"
    node_sg_id      = "sg-0fedcba9876543210"
    backup_policy   = "daily"
    datastores = [
      { name = "q", kind = "queue" },
    ]
  }

  assert {
    condition     = length(aws_sqs_queue.dlq) == 0
    error_message = "a queue with the default max_receive_count (0) must not get a DLQ"
  }
}

# ── reject: a cache name that overflows ElastiCache's 40-char limit ──
run "rejects_cache_name_over_40" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "waytoolongcacheidentifier00", kind = "cache" },
        ]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── reject: an objectStore name that overflows S3's 63-char account-qualified limit ──
run "rejects_object_store_name_over_63" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "an-object-store-name-that-is-far-too-long-to-fit", kind = "objectStore" },
        ]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── reject: a tenant key equal to the environment token (doubled name) ──
run "rejects_tenant_key_equal_to_environment" {
  command = plan

  variables {
    tenants = {
      development = {
        datastores = [{ name = "db", kind = "relational" }]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── reject: an unknown datastore kind ──
run "rejects_unknown_kind" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [{ name = "g", kind = "graph" }]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── the operator's scoping contract: one SSM parameter per relational datastore ──
#
# The tenant role's Secrets Manager grant is scoped to the ARN published here.
# RDS names the managed secret from the cluster's own resource id, so there is no
# convention the operator could scope by instead — if this parameter stops being
# published the only reachable scope is the rds!cluster-* prefix every Aurora
# cluster in the account shares, which is how one tenant ends up able to read
# every other tenant's master credentials. Both directions are asserted: the
# relational store publishes, and no other kind does.
run "relational_publishes_its_master_secret_arn_and_no_other_kind_does" {
  command = plan

  # The mocked provider returns no master_user_secret block, which collapses the
  # module's `try(...)` to null and makes the parameter unwritable. A real apply
  # always populates it — manage_master_user_password = true guarantees it — so
  # the override supplies what RDS would, in the AWS-generated shape the whole
  # scoping problem stems from.
  override_module {
    target = module.tenant.module.relational
    outputs = {
      cluster_arn      = "arn:aws:rds:us-west-2:123456789012:cluster:development-alpha-main"
      cluster_endpoint = "development-alpha-main.cluster-cxyz.us-west-2.rds.amazonaws.com"
      cluster_master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:rds!cluster-4f9c2b1a-Ab3xYz"
      }]
    }
  }

  variables {
    tenants = {
      alpha = {
        datastores = [
          { name = "main", kind = "relational" },
          { name = "docs", kind = "objectStore" },
        ]
      }
    }
  }

  assert {
    condition     = length(aws_ssm_parameter.master_secret_arn) == 1
    error_message = "one SSM parameter per relational datastore, and none for any other kind"
  }

  assert {
    condition     = contains(keys(aws_ssm_parameter.master_secret_arn), "alpha/main")
    error_message = "the relational datastore's master-secret ARN is not published"
  }

  assert {
    condition     = aws_ssm_parameter.master_secret_arn["alpha/main"].name == "/eks-agent-platform/development-platform/tenant-substrate/alpha/main/master_secret_arn"
    error_message = "the parameter must sit in the /eks-agent-platform/<cluster>/ subtree the operator sweeps, keyed by tenant and datastore"
  }
}

# ── every tenant gets its own key, and it reaches the operator ──
#
# The key is not a datastore, so it is minted for every tenant regardless of what
# they declare — a tenant doing envelope encryption in application code needs one
# whether or not it also has a database. The operator cannot compose a KMS ARN
# (AWS generates the key id), so without the published parameter there is nothing
# to scope a grant to except a hand-written policy through extraPolicyArns.
run "every_tenant_gets_its_own_key_published_for_the_operator" {
  command = plan

  override_module {
    target = module.tenant.module.relational
    outputs = {
      cluster_arn      = "arn:aws:rds:us-west-2:123456789012:cluster:development-alpha-main"
      cluster_endpoint = "development-alpha-main.cluster-cxyz.us-west-2.rds.amazonaws.com"
      cluster_master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:rds!cluster-4f9c2b1a-Ab3xYz"
      }]
    }
  }

  variables {
    tenants = {
      alpha = { datastores = [{ name = "main", kind = "relational" }] }
      # No datastores at all — still gets a key, because the key backs
      # application-side encryption, not a datastore.
      beta = { datastores = [] }
    }
  }

  assert {
    condition     = length(aws_ssm_parameter.tenant_kms_key_arn) == 2
    error_message = "every tenant gets a key parameter, including one declaring no datastores"
  }

  assert {
    condition     = aws_ssm_parameter.tenant_kms_key_arn["beta"].name == "/eks-agent-platform/development-platform/tenant-substrate/beta/kms_key_arn"
    error_message = "the key parameter must sit in the subtree the operator sweeps, keyed by tenant"
  }

}

# Distinctness is asserted on the alias rather than the ARN: a mocked provider
# hands every aws_kms_key the same placeholder ARN, so comparing ARNs at plan
# proves nothing. The alias is composed from <environment>-<tenant>, which is
# known at plan, so it discriminates for the reason that actually matters — each
# tenant's key is a separate resource named after that tenant.
run "each_tenant_key_is_named_for_its_own_tenant" {
  command = plan

  module {
    source = "./modules/tenant"
  }

  variables {
    environment     = "development"
    account_id      = "123456789012"
    tenant_id       = "beta"
    datastores      = []
    vpc_id          = "vpc-0123456789abcdef0"
    private_subnets = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id   = "sg-0123456789abcdef0"
    node_sg_id      = "sg-0fedcba9876543210"
    backup_policy   = "daily"
    tags            = {}
  }

  assert {
    condition     = aws_kms_alias.tenant.name == "alias/development-beta-tenant"
    error_message = "the tenant key's alias must be composed from <environment>-<tenant>, so one tenant's key can never be another's"
  }

  assert {
    condition     = aws_kms_key.tenant.enable_key_rotation == true
    error_message = "rotation is free here — nothing pins a key version and both consumers resolve by ARN"
  }
}

# The protected direction. Staging with the lever unset is the posture a real tenant
# runs in: the datastore's own declaration stands, and a destroy is refused at the AWS
# level rather than half-completing. Asserting only the permissive direction would pass
# on a gate that is wired open unconditionally, which is the failure this pair exists to
# catch — a gate is only correct if it holds in both directions.
run "protected_environment_keeps_every_teardown_gate_armed" {
  command = plan

  module {
    source = "./modules/tenant"
  }

  variables {
    environment           = "staging"
    force_destroy_buckets = false
    account_id            = "123456789012"
    tenant_id             = "t1"
    vpc_id                = "vpc-0123456789abcdef0"
    private_subnets       = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id         = "sg-0123456789abcdef0"
    node_sg_id            = "sg-0fedcba9876543210"
    backup_policy         = "daily"
    tags                  = {}
    datastores = [
      { name = "kv", kind = "keyValue", key_value = { partition_key = { name = "pk", type = "S" } } },
      { name = "obj", kind = "objectStore" },
    ]
  }

  assert {
    condition     = aws_dynamodb_table.key_value["kv"].deletion_protection_enabled
    error_message = "a Retain keyValue datastore in a protected environment must keep the DynamoDB backstop"
  }

  assert {
    condition     = aws_s3_bucket.object_store["obj"].force_destroy == false
    error_message = "an object store in a protected environment must not be force-destroyable"
  }
}

# The rendered map, not a fixture.
#
# Every other run in this file feeds a hand-written tenants map, which proves the
# module's behaviour but says nothing about whether the thing a Platform CR
# actually renders into is accepted. This run reads the committed
# tenants.generated.json for development — the same file the leaf reads — so the
# four real tenants and their eighteen datastores are planned here.
#
# What it is really asserting is the variable boundary. tenant-substrate refuses
# a tenant key that repeats the environment token, an unknown kind, a keyValue
# store with no partition key, and five separate composed-name length budgets
# (cache 40, objectStore 63, queue 80, relational 63, stream 64) whose inputs
# include the environment and tenant tokens. A CR whose datastore name is three
# characters too long for its kind fails HERE, on a plan with no credentials,
# rather than at apply against a real account.
run "the_rendered_development_map_is_accepted_and_provisions_every_declared_store" {
  command = plan

  # Same reason as the run above: the mocked provider returns no
  # master_user_secret block, and a real apply always populates it.
  override_module {
    target = module.tenant.module.relational
    outputs = {
      cluster_arn      = "arn:aws:rds:us-west-2:123456789012:cluster:development-rendered-main"
      cluster_endpoint = "development-rendered-main.cluster-cxyz.us-west-2.rds.amazonaws.com"
      cluster_master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:rds!cluster-4f9c2b1a-Ab3xYz"
      }]
    }
  }

  variables {
    tenants = jsondecode(file("../../../live/aws/workload-development/us-west-2/development/tenant-substrate/tenants.generated.json"))
  }

  # The renderer produced something, and this run is not passing over an empty
  # map — which is exactly what it looked like before the renderer existed.
  assert {
    condition     = length(keys(var.tenants)) == 4
    error_message = "expected four rendered tenants, got ${length(keys(var.tenants))} — a render that drops a tenant would otherwise pass every assertion below"
  }

  assert {
    condition     = length(flatten([for t in values(var.tenants) : t.datastores])) == 18
    error_message = "expected eighteen rendered datastores, got ${length(flatten([for t in values(var.tenants) : t.datastores]))}"
  }

  # One customer-managed key per tenant, published for the operator to scope its
  # KMS grant to. Four tenants, four keys, whether or not each declares a store.
  assert {
    condition     = length(aws_ssm_parameter.tenant_kms_key_arn) == 4
    error_message = "one key parameter per tenant"
  }

  # Three relational stores across three different tenants, each publishing the
  # AWS-generated master-secret ARN the operator cannot compose.
  assert {
    condition     = length(aws_ssm_parameter.master_secret_arn) == 3
    error_message = "expected three relational master-secret parameters, got ${length(aws_ssm_parameter.master_secret_arn)}"
  }

  # The datastore identifiers the operator reads back. Asserting the count per
  # kind is what catches a renderer that emitted a store the module then skipped
  # because its kind or config block did not survive the case conversion.
  assert {
    condition = length([
      for t, stores in output.tenant_datastores : 1
      if length(keys(stores)) > 0
    ]) == 4
    error_message = "every tenant must publish at least one datastore identifier"
  }

  assert {
    condition = length(flatten([
      for t, stores in output.tenant_datastores : [for k, v in stores : v if v.kind == "keyValue"]
    ])) == 6
    error_message = "the four CRs declare six keyValue stores"
  }

  assert {
    condition = length(flatten([
      for t, stores in output.tenant_datastores : [for k, v in stores : v if v.kind == "objectStore"]
    ])) == 4
    error_message = "the four CRs declare four objectStore stores"
  }

  assert {
    condition = length(flatten([
      for t, stores in output.tenant_datastores : [for k, v in stores : v if v.kind == "queue"]
    ])) == 4
    error_message = "the four CRs declare four queue stores"
  }

  assert {
    condition = length(flatten([
      for t, stores in output.tenant_datastores : [for k, v in stores : v if v.kind == "cache"]
    ])) == 1
    error_message = "the four CRs declare one cache store"
  }
}

# deletionPolicy: Delete reaches the resource, in a protected environment.
#
# The run above proves a Retain datastore keeps its backstop where the operator's
# lever is closed. This is the other half — that the datastore's own declaration
# can open the gate that its kind actually has, without the operator's lever and
# without touching any other datastore's protection.
#
# keyValue is the kind asserted because it is the one whose lever is a plain
# argument on a first-party resource. relational's lever is an input to the
# upstream rds-aurora module and is not reachable from a plan assertion; its
# polarity is held by scripts/check-teardown-gates.py, which reads the expression
# statically and fails when it stops opening on the lever.
run "a_delete_datastore_opens_its_own_gate_without_the_operator_lever" {
  command = plan

  module {
    source = "./modules/tenant"
  }

  variables {
    environment           = "staging"
    force_destroy_buckets = false
    account_id            = "123456789012"
    tenant_id             = "t1"
    vpc_id                = "vpc-0123456789abcdef0"
    private_subnets       = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id         = "sg-0123456789abcdef0"
    node_sg_id            = "sg-0fedcba9876543210"
    backup_policy         = "daily"
    tags                  = {}
    datastores = [
      { name = "gone", kind = "keyValue", deletion_policy = "Delete", key_value = { partition_key = { name = "pk", type = "S" } } },
      { name = "kept", kind = "keyValue", key_value = { partition_key = { name = "pk", type = "S" } } },
    ]
  }

  assert {
    condition     = aws_dynamodb_table.key_value["gone"].deletion_protection_enabled == false
    error_message = "a Delete datastore must drop its own backstop even in a protected environment — otherwise deletionPolicy is a declaration the API accepts and nothing honours"
  }

  # And it reaches only its own. A per-datastore declaration that leaked across
  # the for_each would disarm a sibling that never asked for it.
  assert {
    condition     = aws_dynamodb_table.key_value["kept"].deletion_protection_enabled
    error_message = "a sibling datastore that did not declare Delete must keep its backstop"
  }
}

# ── ACU bounds ──────────────────────────────────────────────────────────────
#
# The Platform CRD carries the same bounds, and these are not redundant with it.
# var.tenants is rendered from the CRs, but a leaf can be edited directly, and
# for as long as the field existed the CRD's own comment claimed THIS boundary
# enforced the range while nothing here did. A capacity AWS rejects belongs at
# plan, not part-way through an apply that has already created a subnet group.

run "accepts_auto_pause_floor" {
  command = plan

  # The mocked provider returns no master_user_secret block, so the root's SSM
  # parameter is unwritable at plan time. Same override the scoping-contract runs
  # above use — it supplies what RDS would.
  override_module {
    target = module.tenant.module.relational
    outputs = {
      cluster_arn      = "arn:aws:rds:us-west-2:123456789012:cluster:development-t1-db"
      cluster_endpoint = "development-t1-db.cluster-cxyz.us-west-2.rds.amazonaws.com"
      cluster_master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:rds!cluster-4f9c2b1a-Ab3xYz"
      }]
    }
  }

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { min_acu = 0, max_acu = 8 } },
        ]
      }
    }
  }
}

run "accepts_full_acu_range" {
  command = plan

  # The mocked provider returns no master_user_secret block, so the root's SSM
  # parameter is unwritable at plan time. Same override the scoping-contract runs
  # above use — it supplies what RDS would.
  override_module {
    target = module.tenant.module.relational
    outputs = {
      cluster_arn      = "arn:aws:rds:us-west-2:123456789012:cluster:development-t1-db"
      cluster_endpoint = "development-t1-db.cluster-cxyz.us-west-2.rds.amazonaws.com"
      cluster_master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:rds!cluster-4f9c2b1a-Ab3xYz"
      }]
    }
  }

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "lo", kind = "relational", relational = { min_acu = 0.5, max_acu = 1 } },
          { name = "hi", kind = "relational", relational = { min_acu = 255.5, max_acu = 256 } },
          { name = "eq", kind = "relational", relational = { min_acu = 4, max_acu = 4 } },
        ]
      }
    }
  }
}

# ── reject: a floor past Aurora's 256-ACU cap ──
# The CRD pattern admitted values up to 999 for as long as it existed.
#
# The min_acu upper bound is jointly enforced and cannot fire alone: any floor
# above 256 forces either a ceiling above 256 (the max bound) or a ceiling below
# the floor (the relation). It is kept because a reader of the validation should
# see Aurora's real range stated on the field it constrains, and because it
# produces the error naming min_acu rather than only max_acu. Mutating the 256
# in that clause therefore does NOT turn this run red — that is the checks
# overlapping, not a hole.
run "rejects_min_acu_over_cap" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { min_acu = 257, max_acu = 512 } },
        ]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── reject: a ceiling past Aurora's 256-ACU cap, with the floor in range ──
# Isolates the max bound. The run above pairs an out-of-range floor with an
# out-of-range ceiling, so either check alone still rejects it and neither is
# proven load-bearing by it.
run "rejects_max_acu_over_cap" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { min_acu = 0.5, max_acu = 257 } },
        ]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── reject: a capacity off the 0.5-ACU step ──
run "rejects_non_half_step_acu" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { min_acu = 1.25, max_acu = 8 } },
        ]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── reject: a ceiling of zero ──
# Only the floor may be 0; a ceiling of zero leaves no capacity to scale into.
run "rejects_zero_max_acu" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { min_acu = 0, max_acu = 0 } },
        ]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── reject: a ceiling below the floor ──
run "rejects_max_acu_below_min" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { min_acu = 8, max_acu = 0.5 } },
        ]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── reject: auto-pause on an engine that cannot pause ──
# min_acu = 0 on Aurora PostgreSQL below 16.3 is accepted by the API and simply
# never pauses, so the saving the floor was set for silently does not happen.
run "rejects_auto_pause_on_old_engine" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { engine_version = "15.4", min_acu = 0, max_acu = 8 } },
        ]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── reject: auto-pause on 16.2, which is major-16 but below the 16.3 bar ──
# This is the case that exercises the MINOR comparison. The 15.4 run above is
# settled by the major alone, so on its own it leaves the minor bound untested —
# mutating `>= 3` to `>= 0` left that run green.
run "rejects_auto_pause_on_16_2" {
  command = plan

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { engine_version = "16.2", min_acu = 0, max_acu = 8 } },
        ]
      }
    }
  }

  expect_failures = [var.tenants]
}

# ── accept: the same old engine with a non-zero floor ──
# The engine bound applies only to auto-pause, so it must not become a general
# floor on engine_version.
run "accepts_old_engine_with_nonzero_floor" {
  command = plan

  # The mocked provider returns no master_user_secret block, so the root's SSM
  # parameter is unwritable at plan time. Same override the scoping-contract runs
  # above use — it supplies what RDS would.
  override_module {
    target = module.tenant.module.relational
    outputs = {
      cluster_arn      = "arn:aws:rds:us-west-2:123456789012:cluster:development-t1-db"
      cluster_endpoint = "development-t1-db.cluster-cxyz.us-west-2.rds.amazonaws.com"
      cluster_master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:rds!cluster-4f9c2b1a-Ab3xYz"
      }]
    }
  }

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { engine_version = "15.4", min_acu = 0.5, max_acu = 8 } },
        ]
      }
    }
  }
}

# ── accept: 16.10 is newer than 16.3, not older ──
# The minor is compared as a number precisely so a string compare cannot make
# "16.10" read as below "16.3".
run "accepts_auto_pause_on_double_digit_minor" {
  command = plan

  # The mocked provider returns no master_user_secret block, so the root's SSM
  # parameter is unwritable at plan time. Same override the scoping-contract runs
  # above use — it supplies what RDS would.
  override_module {
    target = module.tenant.module.relational
    outputs = {
      cluster_arn      = "arn:aws:rds:us-west-2:123456789012:cluster:development-t1-db"
      cluster_endpoint = "development-t1-db.cluster-cxyz.us-west-2.rds.amazonaws.com"
      cluster_master_user_secret = [{
        secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:rds!cluster-4f9c2b1a-Ab3xYz"
      }]
    }
  }

  variables {
    tenants = {
      t1 = {
        datastores = [
          { name = "db", kind = "relational", relational = { engine_version = "16.10", min_acu = 0, max_acu = 8 } },
        ]
      }
    }
  }
}
