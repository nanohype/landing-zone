terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Partial S3 backend. A provider-terraform Workspace fills bucket/key/region via
  # its backendConfig; for local checks run `tofu init -backend=false`.
  backend "s3" {}
}
