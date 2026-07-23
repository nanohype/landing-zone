variable "environment" {
  description = "Environment name — the leading token of every datastore's resource name."
  type        = string
}

variable "region" {
  description = "AWS region — used to compose resource ARNs in the outputs."
  type        = string
}

variable "account_id" {
  description = "AWS account ID — embedded into S3 bucket names for global uniqueness."
  type        = string
}

variable "tenant_id" {
  description = "Tenant identifier — the middle token of every datastore's resource name. The component-level tenants validation proves the composed names fit each service's limit."
  type        = string
}

variable "datastores" {
  description = "The tenant's declared datastores, mirroring the Platform CR's spec.datastores. Each entry names a datastore and its kind, carrying at most the one config block matching that kind (stream carries none); an omitted block takes the young/light defaults."
  type = list(object({
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
}

variable "vpc_id" {
  description = "VPC the datastore security groups attach to."
  type        = string
}

variable "private_subnets" {
  description = "Private subnet IDs for the Aurora, ElastiCache, and MSK subnet groups."
  type        = list(string)
}

variable "cluster_sg_id" {
  description = "EKS cluster security group ID — the only source allowed into each datastore's port."
  type        = string
}

variable "backup_policy" {
  description = "Value of the BackupPolicy tag stamped on every datastore, so the central backup plan's tag selector picks it up."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
