locals {
  cloud_vars   = read_terragrunt_config(find_in_parent_folders("cloud.hcl"))
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  env_vars     = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  cloud       = local.cloud_vars.locals.cloud
  region      = local.region_vars.locals.region
  environment = local.env_vars.locals.environment

  # Cloud-specific identifiers (try() for cross-cloud safety)
  account_id      = try(local.account_vars.locals.account_id, "")
  project_id      = try(local.account_vars.locals.project_id, "")
  subscription_id = try(local.account_vars.locals.subscription_id, "")
  azure_tenant_id = try(local.account_vars.locals.tenant_id, "")

  # Common metadata
  cost_center         = local.env_vars.locals.cost_center
  business_unit       = local.env_vars.locals.business_unit
  data_classification = local.env_vars.locals.data_classification
  compliance          = local.env_vars.locals.compliance
  repository          = local.env_vars.locals.repository
}

# --- Common inputs ---
# region + environment are declared (no default) by every component, so the
# root passes the resolved values down. Component-specific inputs (team,
# cluster_name, tenants, …) come from each component's _envcommon/*.hcl.
inputs = {
  region      = local.region
  environment = local.environment
}

# --- AWS Provider ---
generate "provider_aws" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  disable   = local.cloud != "aws"
  contents  = <<EOF
provider "aws" {
  region = "${local.region}"
  default_tags {
    tags = {
      Environment        = "${local.environment}"
      ManagedBy          = "opentofu"
      Project            = "landing-zone"
      CostCenter         = "${local.cost_center}"
      BusinessUnit       = "${local.business_unit}"
      DataClassification = "${local.data_classification}"
      Compliance         = "${local.compliance}"
      Repository         = "${local.repository}"
    }
  }
}
EOF
}

# --- GCP Provider ---
generate "provider_gcp" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  disable   = local.cloud != "gcp"
  contents  = <<EOF
provider "google" {
  project = "${local.project_id}"
  region  = "${local.region}"
  default_labels = {
    environment          = "${lower(local.environment)}"
    managed_by           = "opentofu"
    project              = "landing-zone"
    cost_center          = "${lower(replace(local.cost_center, "-", "_"))}"
    business_unit        = "${lower(replace(local.business_unit, "-", "_"))}"
    data_classification  = "${lower(replace(local.data_classification, "-", "_"))}"
    compliance           = "${lower(local.compliance)}"
    repository           = "${lower(replace(local.repository, "/", "_"))}"
  }
}
EOF
}

# --- Azure Provider ---
generate "provider_azure" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  disable   = local.cloud != "azure"
  contents  = <<EOF
provider "azurerm" {
  subscription_id = "${local.subscription_id}"
  tenant_id       = "${local.azure_tenant_id}"
  features {}
}
EOF
}

# --- Remote State (cloud-dispatched) ---
remote_state {
  backend = local.cloud == "gcp" ? "gcs" : (local.cloud == "azure" ? "azurerm" : "s3")

  config = merge(
    local.cloud == "aws" ? {
      encrypt      = true
      bucket       = "${local.account_id}-${local.region}-tfstate"
      key          = "${local.environment}/${path_relative_to_include()}/terraform.tfstate"
      region       = local.region
      use_lockfile = true
    } : {},
    local.cloud == "gcp" ? {
      bucket = "${local.project_id}-${local.region}-tfstate"
      prefix = "${local.environment}/${path_relative_to_include()}"
    } : {},
    local.cloud == "azure" ? {
      resource_group_name  = "tfstate-rg"
      storage_account_name = "tfstate${substr(replace(local.subscription_id, "-", ""), 0, 12)}"
      container_name       = "tfstate"
      key                  = "${local.environment}/${path_relative_to_include()}/terraform.tfstate"
    } : {}
  )

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
