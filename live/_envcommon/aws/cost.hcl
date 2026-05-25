terraform {
  source = "${dirname(find_in_parent_folders("cloud.hcl"))}/../..//components/aws/cost"
}

inputs = {
  enable_tenant_anomaly_detection = false
  tenant_names                    = []
  team                            = "finops"
}
