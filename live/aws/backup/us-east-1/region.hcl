locals {
  # The central backup vault's region. The whole estate now runs in us-east-1 (the org
  # SCP permits only that), so this is no longer a SEPARATE region from the substrate —
  # cross-region durability is not available while the region lock stands. Kept as its
  # own file because the vault's region is a distinct decision from any workload's, and
  # _envcommon/aws/backup.hcl reads THIS file to compose the destination ARN.
  # here so a recovery point survives the loss of the primary region (region-model R4).
  region = "us-east-1"
}
