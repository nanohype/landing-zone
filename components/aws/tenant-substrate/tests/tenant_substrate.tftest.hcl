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
    region          = "us-west-2"
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
run "queue_without_redrive_has_no_dlq" {
  command = plan

  module {
    source = "./modules/tenant"
  }

  variables {
    environment     = "development"
    region          = "us-west-2"
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
