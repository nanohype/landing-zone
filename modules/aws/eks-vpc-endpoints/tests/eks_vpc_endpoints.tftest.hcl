# Unit tests for the eks-vpc-endpoints module — the private endpoint set every EKS
# VPC on the platform shares (consumed by both the create-mode `network` component
# and the `shared-network` owner). Runs at `command = plan` against a mocked AWS
# provider (no account, no network), so it gates the module's one real decision:
# which endpoints the set contains, and specifically that the EKS API interface
# endpoint is conditional on var.enable_eks_interface_endpoint.
#
# The endpoint set is what makes the private-by-default cluster reachable without
# NAT; the EKS interface endpoint is deliberately toggled OFF for an eks-fleet
# provisioning hub (its private DNS shadows the OIDC issuer). The gateway and
# interface halves toggle independently (enable_s3_gateway_endpoint /
# enable_interface_endpoints) so a minimal-footprint VPC can keep the free S3
# gateway while dropping the paid interface set. A regression that always creates
# the EKS endpoint, drops an always-on endpoint, or ignores a toggle is what this bites.

mock_provider "aws" {
  mock_data "aws_vpc_endpoint_service" {
    defaults = {
      service_name = "com.amazonaws.us-west-2.mock"
    }
  }
}

variables {
  vpc_id             = "vpc-0mock"
  private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
  route_table_ids    = ["rtb-a", "rtb-b"]
  security_group_id  = "sg-0mock"
  environment        = "development"
}

# ── default: the full always-on endpoint set PLUS the conditional EKS API endpoint ──
run "default_includes_eks_interface_endpoint" {
  command = plan

  assert {
    condition = alltrue([
      for e in ["s3", "ecr_api", "ecr_dkr", "secretsmanager", "ssm", "sts", "eks_auth", "aps_workspaces"] :
      contains(keys(output.endpoints), e)
    ])
    error_message = "the always-on endpoint set (s3, ecr_api, ecr_dkr, secretsmanager, ssm, sts, eks_auth, aps_workspaces) must always be present"
  }

  assert {
    condition     = contains(keys(output.endpoints), "eks")
    error_message = "the EKS API interface endpoint must be created when enable_eks_interface_endpoint is true (the default)"
  }
}

# ── hub posture: the EKS API interface endpoint is dropped, everything else stays ──
run "hub_drops_eks_interface_endpoint" {
  command = plan

  variables {
    enable_eks_interface_endpoint = false
  }

  assert {
    condition     = !contains(keys(output.endpoints), "eks")
    error_message = "enable_eks_interface_endpoint = false must NOT create the EKS API interface endpoint (it shadows the OIDC issuer on a provisioning hub)"
  }

  # eks-auth is a sibling service, not the EKS API endpoint — it must stay on even
  # when the EKS interface endpoint is dropped, or Pod Identity loses its private path.
  assert {
    condition     = contains(keys(output.endpoints), "eks_auth")
    error_message = "eks_auth must stay on even with the EKS interface endpoint off — it serves Pod Identity, not the EKS API"
  }
}

# ── minimal footprint: interface endpoints off, the free S3 gateway stays ──
run "gateway_only_drops_interface_set" {
  command = plan

  variables {
    enable_interface_endpoints = false
    security_group_id          = "" # not required when interface endpoints are off
  }

  assert {
    condition     = keys(output.endpoints) == ["s3"]
    error_message = "with interface endpoints off, only the S3 gateway endpoint must remain"
  }
}

# ── gateway also off: an empty endpoint set (both halves toggled off) ──
run "both_halves_off_is_empty" {
  command = plan

  variables {
    enable_s3_gateway_endpoint = false
    enable_interface_endpoints = false
    security_group_id          = ""
  }

  assert {
    condition     = length(keys(output.endpoints)) == 0
    error_message = "with both halves off, no endpoints are created"
  }
}
