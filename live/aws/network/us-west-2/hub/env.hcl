locals {
  # The shared central-egress hub is not per-workload-environment — one hub serves every
  # spoke (dev, staging, production) that flips centralized_egress, because the org runs a
  # single transit gateway with a single default route table. It carries production traffic,
  # so it is treated at production sensitivity.
  environment         = "hub"
  cost_center         = "platform-engineering"
  business_unit       = "engineering"
  data_classification = "confidential"
  compliance          = "soc2"
  repository          = "nanohype/landing-zone"
  owner               = "platform-engineering"
}
