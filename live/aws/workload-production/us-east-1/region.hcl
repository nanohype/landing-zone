locals {
  # The account's home region. The org SCP `guardrail-region-lock` on the Ventures
  # OU denies every action whose aws:RequestedRegion is not us-east-1, so this is
  # the only region a leaf in this account can be applied into.
  region = "us-east-1"
}
