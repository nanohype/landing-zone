locals {
  # The DR region. The primary substrate runs in us-west-2; the central backup vault lives
  # here so a recovery point survives the loss of the primary region (region-model R4).
  region = "us-east-1"
}
