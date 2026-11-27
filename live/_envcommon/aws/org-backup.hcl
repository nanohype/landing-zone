terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/org-backup"
}

# org-backup runs in the management account. It enables org-wide cross-account backup,
# registers the backup account as the AWS Backup delegated administrator, and attaches an
# Organizations backup policy that backs up every BackupPolicy-tagged resource in every
# member account to that account's Default vault — a floor accounts cannot opt out of. The
# copy to the central vault stays the workload backup component's (see the leaf).
inputs = {
  team = "sre"
}
