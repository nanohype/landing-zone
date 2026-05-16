config {
  call_module_type = "local"
}

plugin "azurerm" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}

rule "terraform_naming_convention" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

# The Dsv6 family went GA in mid-2025 but the bundled tflint azurerm
# ruleset (0.27.0, released earlier) flags `Standard_D4s_v6` as
# "invalid". Dsv5 has zero default quota in westus2 (and others), so
# Dsv6 is the right default. Disable the rule rather than pin to an
# unbuildable VM size; pick a newer ruleset version when one is published.
rule "azurerm_kubernetes_cluster_default_node_pool_invalid_vm_size" {
  enabled = false
}
