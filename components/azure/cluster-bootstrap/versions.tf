terraform {
  required_version = ">= 1.10.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    # kubectl provider (gavinbunney) defers CRD schema validation to apply
    # time. The hashicorp/kubernetes provider's `kubernetes_manifest` validates
    # at plan time, which fails on a fresh cluster where Argo / External
    # Secrets CRDs don't exist yet. Use kubectl_manifest for any custom-
    # resource bootstrapping.
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.19"
    }
  }
}
