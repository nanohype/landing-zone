include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/org-security.hcl"
  merge_strategy = "deep"
}

inputs = {
  enable_guardduty    = true
  enable_security_hub = true

  guardduty_features = {
    s3_protection           = true
    eks_audit_logs          = true
    eks_runtime_monitoring  = true
    malware_protection      = true
    rds_login_events        = false
    lambda_network_activity = false
  }

  member_accounts = {}

  securityhub_standards = [
    "arn:aws:securityhub:::ruleset/cis-aws-foundations-benchmark/v/3.0.0",
    "arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0",
  ]

  enable_cross_region_aggregation = false
  alert_email_endpoints           = []
}
