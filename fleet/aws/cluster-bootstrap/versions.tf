terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    # alekc/kubectl is the maintained fork of gavinbunney/kubectl, which has
    # stopped releasing: its last release links dependency versions with known
    # vulnerabilities, fixed upstream but never taken.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 3.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Partial S3 backend. A provider-opentofu Workspace fills bucket/key/region via
  # its initArgs; for local checks run `tofu init -backend=false`.
  backend "s3" {}
}
