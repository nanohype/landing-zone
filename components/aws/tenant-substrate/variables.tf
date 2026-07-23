variable "environment" {
  description = "Environment name (development, staging, production) — the leading token of every datastore's resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.environment))
    error_message = "environment must be lowercase, start with a letter, and contain only letters, digits, and hyphens."
  }
}

# tflint-ignore: terraform_unused_declarations
variable "region" {
  description = "AWS region. Declared for envcommon interface uniformity; this component composes no region-qualified names of its own — every datastore ARN carries the region from the resource itself."
  type        = string
}

variable "vpc_id" {
  description = "VPC the datastore security groups attach to."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the Aurora, ElastiCache, and MSK subnet groups."
  type        = list(string)
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID — the only source allowed into each datastore's port."
  type        = string
}

# tflint-ignore: terraform_unused_declarations
variable "cluster_name" {
  description = "Name of the EKS cluster. Declared for envcommon interface uniformity; this component provisions datastores only — the operator owns the Pod Identity association that consumes the cluster name."
  type        = string
}

variable "backup_policy" {
  description = "Value of the BackupPolicy tag stamped on every datastore, so the central backup plan's tag selector picks it up. The tag matches an aws_backup_selection key."
  type        = string
  default     = "daily"
}

variable "tenants" {
  description = "Per-tenant datastore declarations, keyed by tenant id and mirroring each Platform CR's spec.datastores. Rendered from the CRs by the factory, not hand-authored. Each tenant declares a list of datastores; each datastore names a kind and carries at most the one config block matching it."
  type = map(object({
    datastores = list(object({
      name            = string
      kind            = string
      deletion_policy = optional(string, "Retain")
      relational = optional(object({
        engine_version        = optional(string, "16.6")
        min_acu               = optional(number, 0.5)
        max_acu               = optional(number, 8)
        backup_retention_days = optional(number, 7)
        deletion_protection   = optional(bool, true)
      }), {})
      key_value = optional(object({
        partition_key          = object({ name = string, type = string })
        sort_key               = optional(object({ name = string, type = string }))
        billing_mode           = optional(string, "PAY_PER_REQUEST")
        ttl_attribute          = optional(string)
        point_in_time_recovery = optional(bool, true)
        global_secondary_indexes = optional(list(object({
          name          = string
          partition_key = object({ name = string, type = string })
          sort_key      = optional(object({ name = string, type = string }))
          projection    = optional(string, "ALL")
        })), [])
      }))
      object_store = optional(object({
        versioning            = optional(bool, true)
        lifecycle_expire_days = optional(number, 0)
      }), {})
      queue = optional(object({
        fifo                       = optional(bool, false)
        visibility_timeout_seconds = optional(number, 30)
        message_retention_seconds  = optional(number, 345600)
        max_receive_count          = optional(number, 0)
      }), {})
      cache = optional(object({
        engine    = optional(string, "valkey")
        node_type = optional(string, "cache.t4g.micro")
        replicas  = optional(number, 0)
      }), {})
    }))
  }))
  default = {}

  # no-doubled-env: a tenant key that repeats the environment token composes into
  # a doubled "<env>-<env>-…" resource name.
  validation {
    condition     = alltrue([for k in keys(var.tenants) : k != var.environment && !startswith(k, "${var.environment}-")])
    error_message = "a tenant key must not equal or be prefixed with the environment token '${var.environment}-': it composes into a doubled '<env>-<env>…' resource name."
  }

  # every datastore's kind is one of the six.
  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : contains(["relational", "keyValue", "objectStore", "queue", "cache", "stream"], d.kind)
      ]
    ]))
    error_message = "each datastore kind must be one of: relational, keyValue, objectStore, queue, cache, stream."
  }

  # a keyValue datastore must carry its block — a DynamoDB table has no default
  # partition key. Every other kind may omit its block and take the defaults.
  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : d.key_value != null if d.kind == "keyValue"
      ]
    ]))
    error_message = "a keyValue datastore requires its 'key_value' block: a DynamoDB table has no default partition key."
  }

  # datastore names are unique within a tenant (they key the resource maps).
  validation {
    condition = alltrue([
      for tk, tv in var.tenants : length(tv.datastores) == length(distinct([for d in tv.datastores : d.name]))
    ])
    error_message = "datastore names must be unique within a tenant."
  }

  # cache replication_group_id budget: "<env>-<tenant>-<datastore>" <= 40 (the
  # tightest AWS limit any datastore composes against).
  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : length("${var.environment}-${tk}-${d.name}") <= 40 if d.kind == "cache"
      ]
    ]))
    error_message = "a cache datastore name is too long: '<env>-<tenant>-<datastore>' must fit ElastiCache's 40-char replication_group_id limit. With environment='${var.environment}', a tenant+datastore has at most ${40 - length(var.environment) - 2} chars combined."
  }

  # S3 bucket budget: "<env>-<tenant>-<datastore>-<account:12>" <= 63.
  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : length("${var.environment}-${tk}-${d.name}-000000000000") <= 63 if d.kind == "objectStore"
      ]
    ]))
    error_message = "an objectStore datastore name is too long: '<env>-<tenant>-<datastore>-<account:12>' must fit S3's 63-char limit. With environment='${var.environment}', a tenant+datastore has at most ${63 - length(var.environment) - 15} chars combined."
  }

  # SQS budget: the DLQ FIFO name "<env>-<tenant>-<datastore>-dlq.fifo" <= 80 is
  # the longest a queue composes.
  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : length("${var.environment}-${tk}-${d.name}-dlq.fifo") <= 80 if d.kind == "queue"
      ]
    ]))
    error_message = "a queue datastore name is too long: '<env>-<tenant>-<datastore>-dlq.fifo' must fit SQS's 80-char name limit."
  }

  # Aurora instance identifier budget: the module names the instance
  # "<env>-<tenant>-<datastore>-one" and RDS caps identifiers at 63.
  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : length("${var.environment}-${tk}-${d.name}-one") <= 63 if d.kind == "relational"
      ]
    ]))
    error_message = "a relational datastore name is too long: '<env>-<tenant>-<datastore>-one' (the Aurora instance identifier) must fit RDS's 63-char limit."
  }

  # MSK Serverless cluster name budget: "<env>-<tenant>-<datastore>" <= 64.
  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : length("${var.environment}-${tk}-${d.name}") <= 64 if d.kind == "stream"
      ]
    ]))
    error_message = "a stream datastore name is too long: '<env>-<tenant>-<datastore>' must fit MSK's 64-char cluster-name limit."
  }
}

variable "team" {
  description = "Owning team for this component (drives the Team tag)."
  type        = string
}

variable "tags" {
  description = "Additional tags merged into every resource."
  type        = map(string)
  default     = {}
}
