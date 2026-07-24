locals {
  # A single fleet-wide instance, not a per-workload environment — one alarm destination for
  # every cluster in the org. The "shared" token names that instance.
  environment         = "shared"
  cost_center         = "platform-engineering"
  business_unit       = "engineering"
  data_classification = "internal"
  compliance          = "soc2"
  repository          = "nanohype/landing-zone"
  owner               = "platform-engineering"
}
