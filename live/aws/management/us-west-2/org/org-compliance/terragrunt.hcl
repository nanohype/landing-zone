include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/org-compliance.hcl"
  merge_strategy = "deep"
}

inputs = {
  enable_cloudtrail       = true
  enable_org_trail        = true
  enable_log_insights     = true
  cloudtrail_s3_retention = 2555

  enable_config            = true
  enable_config_aggregator = true

  config_rules = {
    required-tags = {
      source_identifier = "REQUIRED_TAGS"
      input_parameters = {
        tag1Key = "Environment"
        tag2Key = "ManagedBy"
        tag3Key = "CostCenter"
        tag4Key = "BusinessUnit"
        tag5Key = "DataClassification"
        tag6Key = "Team"
      }
    }
    s3-bucket-ssl-requests-only = {
      source_identifier = "S3_BUCKET_SSL_REQUESTS_ONLY"
      input_parameters  = {}
    }
    encrypted-volumes = {
      source_identifier = "ENCRYPTED_VOLUMES"
      input_parameters  = {}
    }
    rds-storage-encrypted = {
      source_identifier = "RDS_STORAGE_ENCRYPTED"
      input_parameters  = {}
    }
    iam-password-policy = {
      source_identifier = "IAM_PASSWORD_POLICY"
      input_parameters  = {}
    }
    root-account-mfa-enabled = {
      source_identifier = "ROOT_ACCOUNT_MFA_ENABLED"
      input_parameters  = {}
    }
    cloud-trail-enabled = {
      source_identifier = "CLOUD_TRAIL_ENABLED"
      input_parameters  = {}
    }
    guardduty-enabled-centralized = {
      source_identifier = "GUARDDUTY_ENABLED_CENTRALIZED"
      input_parameters  = {}
    }
    eks-cluster-oldest-supported-version = {
      source_identifier = "EKS_CLUSTER_OLDEST_SUPPORTED_VERSION"
      input_parameters  = {}
    }
    vpc-flow-logs-enabled = {
      source_identifier = "VPC_FLOW_LOGS_ENABLED"
      input_parameters  = {}
    }
  }

  conformance_packs = [
    "Operational-Best-Practices-for-Amazon-EKS",
  ]

  # Backup coverage, checked across every member account (the resources live in the workload
  # accounts, not here). The detective half of central-backup's coverage enforcement: the
  # protection check catches a backup-eligible resource silently protected by no plan, and the
  # frequency/retention check catches a plan weaker than the 24h RPO / 35-day DR floor.
  organization_managed_rules = {
    backup-resources-protected = {
      rule_identifier = "BACKUP_RESOURCES_PROTECTED_BY_BACKUP_PLAN"
      description     = "A backup-eligible resource (Aurora, RDS, DynamoDB, S3, EFS, ...) protected by no backup plan is silently unprotected."
    }
    backup-plan-min-frequency-retention = {
      rule_identifier = "BACKUP_PLAN_MIN_FREQUENCY_AND_MIN_RETENTION_CHECK"
      description     = "A backup plan whose frequency or retention is weaker than the 24h RPO / 35-day DR floor."
      input_parameters = {
        requiredFrequencyValue = "1"
        requiredFrequencyUnit  = "days"
        requiredRetentionDays  = "35"
      }
    }
  }
}
