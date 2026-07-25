# Unit tests for tenant-substrate — the generic per-tenant datastore substrate.
#
# Two contracts under test. (1) The variable-boundary name-length proof: a
# datastore name that would overflow a service's identifier limit — ElastiCache's
# 40-char replication_group_id, S3's 63-char bucket name — is rejected by the
# component's `tenants` validation before any resource is composed, and so is a
# tenant key that doubles the environment token or an unknown kind. (2) Every
# datastore the module mints carries the BackupPolicy tag the central backup plan
# selects on, a redrive-configured queue gets its dead-letter queue, and a Retain
# datastore gets the AWS-level deletion backstop.
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

# ── shared component-level inputs for the validation runs ──
variables {
  environment        = "development"
  region             = "us-west-2"
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  cluster_sg_id      = "sg-0123456789abcdef0"
  cluster_name       = "development-platform"
  team               = "platform"
  tenants            = {}
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
    vpc_id          = "vpc-0123456789abcdef0"
    private_subnets = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id   = "sg-0123456789abcdef0"
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

  # a Retain datastore (the default policy) gets the AWS-level deletion backstop.
  assert {
    condition     = aws_dynamodb_table.key_value["kv"].deletion_protection_enabled
    error_message = "a Retain keyValue datastore must enable DynamoDB deletion protection"
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
    vpc_id          = "vpc-0123456789abcdef0"
    private_subnets = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id   = "sg-0123456789abcdef0"
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
    condition     = aws_s3_bucket.object_store["loose"].tags["Tenant"] == "t1"
    error_message = "withholding BackupPolicy must not drop the tenant tags"
  }
  assert {
    condition     = aws_dynamodb_table.key_value["kv"].tags["BackupPolicy"] == "daily"
    error_message = "the versioning gate is S3-only; other datastore kinds keep BackupPolicy unconditionally"
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
    vpc_id          = "vpc-0123456789abcdef0"
    private_subnets = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
    cluster_sg_id   = "sg-0123456789abcdef0"
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
