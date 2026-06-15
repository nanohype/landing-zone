terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # Partial S3 backend. A provider-opentofu Workspace fills bucket/key/region via
  # its backendConfig; for local checks run `tofu init -backend=false`.
  backend "s3" {}
}
