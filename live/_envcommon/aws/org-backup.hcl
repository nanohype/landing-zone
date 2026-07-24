terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/org-backup"
}

# org-backup runs in the management account. It enables org-wide cross-account backup,
# registers the backup account as the AWS Backup delegated administrator, and attaches an
# Organizations backup policy that backs up every BackupPolicy-tagged resource in every
# member account and copies it to the central vault — a floor accounts cannot opt out of.
inputs = {
  team = "sre"
}
