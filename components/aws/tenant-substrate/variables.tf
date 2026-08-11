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

variable "node_sg_id" {
  description = "EKS node security group ID — the source of every packet a pod sends out of the cluster, and therefore the only thing a datastore's ingress rule can usefully allow."
  type        = string
}

# tflint-ignore: terraform_unused_declarations
variable "cluster_sg_id" {
  description = "EKS cluster security group ID. Declared for envcommon interface uniformity and deliberately not read: it is attached to the CONTROL PLANE's ENIs, so no packet a pod sends carries it, and a datastore admitting it accepts connections from nobody. The group that matters is node_sg_id."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Keys the SSM subtree this component publishes each tenant's RDS-managed master-secret ARN into, matching the /eks-agent-platform/<cluster>/ tree the operator sweeps — so co-located sibling clusters resolve isolated substrates."
  type        = string
}

variable "backup_policy" {
  description = <<-EOT
    Value of the BackupPolicy tag, matching an aws_backup_selection key in the backup
    component so the central plan's tag selector picks the resource up.

    Stamped only on the datastore kinds AWS Backup can protect: relational (Aurora),
    keyValue (DynamoDB), and objectStore (S3, and only when its versioning is Enabled —
    AWS Backup requires it). The queue, cache and stream kinds are not supported resource
    types, so they are left untagged rather than carrying a claim the plan can never
    honour; their real durability is documented per kind in modules/tenant/locals.tf.
  EOT
  type        = string
  default     = "daily"

  # A value that matches no plan key selects nothing, so it reads as protected while being
  # ignored. This root cannot see the backup component's keys, so it asserts the shape only.
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.backup_policy))
    error_message = "backup_policy must be a lowercase plan key (letters, digits, hyphens) matching a key in the backup component's backup_plans."
  }
}

variable "tenants" {
  description = "Per-tenant datastore declarations, keyed by tenant id and mirroring each Platform CR's spec.datastores. Rendered from the CRs by the factory, not hand-authored. Each tenant declares a list of datastores; each datastore names a kind and carries at most the one config block matching it."
  type = map(object({
    datastores = list(object({
      name            = string
      kind            = string
      deletion_policy = optional(string, "Retain")
      relational = optional(object({
        # Major-only by design. RDS resolves it to the newest minor the region
        # offers, so a retired patch cannot strand the component: pinned at
        # "16.6", this failed every apply with `Cannot find version 16.6 for
        # aurora-postgresql` once AWS withdrew it — after the VPC and the EKS
        # cluster were already built and billing. Pin a full version only to
        # hold a tenant on one, and expect to move it when AWS retires it.
        engine_version        = optional(string, "16")
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

  # Aurora Serverless v2 capacity is 0.5–256 ACU in half-ACU steps, plus 0 on the
  # floor only, which is the auto-pause setting. The Platform CRD carries the same
  # bounds, and this is not redundant with it: var.tenants is rendered from the
  # CRs but the leaf can be edited directly, and the CRD's own comment used to
  # claim this boundary enforced the range while nothing here did. A capacity AWS
  # rejects should fail at plan, not part-way through an apply.
  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : (
          d.relational.min_acu == 0 ||
          (d.relational.min_acu >= 0.5 && d.relational.min_acu <= 256 && d.relational.min_acu % 0.5 == 0)
        ) if d.kind == "relational"
      ]
    ]))
    error_message = "a relational datastore's min_acu must be 0 (Serverless v2 auto-pause) or between 0.5 and 256 in 0.5-ACU steps."
  }

  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : (
          d.relational.max_acu >= 0.5 && d.relational.max_acu <= 256 && d.relational.max_acu % 0.5 == 0
        ) if d.kind == "relational"
      ]
    ]))
    error_message = "a relational datastore's max_acu must be between 0.5 and 256 in 0.5-ACU steps. Unlike the floor it cannot be 0 — a ceiling of zero leaves no capacity to scale into."
  }

  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : d.relational.max_acu >= d.relational.min_acu if d.kind == "relational"
      ]
    ]))
    error_message = "a relational datastore's max_acu must be >= its min_acu."
  }

  # Auto-pause needs Aurora PostgreSQL 16.3 or later. Below that a min_acu of 0
  # is accepted by the API and simply never pauses, so the cost saving the floor
  # was set for silently does not happen. The minor is compared as a number so
  # 16.10 does not read as older than 16.3.
  #
  # A major-only version ("16") satisfies the rule. RDS resolves it to the newest
  # minor available in the region, and every 16.x AWS still offers is past 16.3 —
  # the versions below it were the first two releases of the line and are long
  # gone. Treating the absent minor as "whatever is current" is the only reading
  # that matches what the API will actually create.
  validation {
    condition = alltrue(flatten([
      for tk, tv in var.tenants : [
        for d in tv.datastores : (
          d.relational.min_acu != 0 ||
          tonumber(split(".", d.relational.engine_version)[0]) > 16 ||
          (tonumber(split(".", d.relational.engine_version)[0]) == 16 &&
            (length(split(".", d.relational.engine_version)) == 1 ||
          tonumber(split(".", d.relational.engine_version)[1]) >= 3))
        ) if d.kind == "relational"
      ]
    ]))
    error_message = "min_acu = 0 is Aurora Serverless v2 auto-pause, which requires Aurora PostgreSQL 16.3 or later. Raise engine_version or set a non-zero floor."
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

variable "force_destroy_buckets" {
  description = <<-EOT
    Permit a full teardown of this component in any environment: empty its S3 object stores,
    skip Aurora's final snapshot, and clear deletion protection on both Aurora and any Retain
    key-value table. Development already permits all of it unconditionally; this is the opt-in
    for everywhere else.

    One lever, every gate. deletion_policy is a datastore's declaration about its own data;
    this flag is the operator's declaration about the whole substrate, and the operator's wins.
    The alternative is a Retain table that survives while its own objectStore empties around
    it, wedging the reverse sweep with nothing protected.

    It exists because a cluster here is an agent-managed, often short-lived thing — eks-fleet
    vends spokes with a ttlDays and a hub reaper that deletes them on expiry — so a teardown is
    an ordinary lifecycle event rather than an emergency. Without this, a reverse teardown of a
    non-development spoke wedges on BucketNotEmpty / missing final_snapshot_identifier and
    leaves the cluster, VPC and NAT gateways standing and billing.

    Deliberately two acts, not one flag: none of it takes effect until a successful apply lands
    it in state, so an operator (or an agent) must apply with this set and only then destroy.
    There is no single command that reaches a populated production object store or drops a
    production Aurora.

    What it exposes: every Platform-declared objectStore (versioning defaults Enabled), every
    relational Aurora, and every Retain keyValue table, for every tenant on this cluster. Leave
    it false unless the cluster is genuinely disposable.
  EOT
  type        = bool
  default     = false
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
