# Owner-side contract assertions. These are the half of the adopt contract a participant
# account CANNOT verify from its own side: the consumer's adopt preflight (in the `network`
# component) can observe the S3 gateway route and a live default egress route on the shared
# route tables, but it cannot DescribeVpcEndpoints on foreign interface endpoints and cannot
# see owner-written subnet tags through RAM. So the owner asserts endpoint completeness, the
# role-tag convention, and that a consumer is actually declared — here, where it is
# observable — and the README documents the same contract in prose for anyone hand-rolling a
# non-terraform owner network against it.
#
# check blocks surface a contract breach as a plan/apply warning (non-blocking by design),
# and the tofu test suite gates them hard via expect_failures — so a regression that guts
# the endpoint set or forgets the consumers fails CI, not just the next apply's log.

locals {
  # The endpoint set an adopting EKS cluster and its addons need over the data path. eks is
  # intentionally excluded from the required set — it is conditional (a provisioning hub
  # turns it off so it doesn't shadow the OIDC issuer), so its absence is not a breach.
  required_endpoint_services = toset([
    "s3", "ecr_api", "ecr_dkr", "secretsmanager", "ssm", "sts", "eks_auth", "aps_workspaces",
  ])

  # Keys are the endpoint config names, known at plan even when the endpoint resources
  # themselves are known-after-apply. The ternary short-circuits when endpoints are off, so
  # the [0] index is never evaluated against a count-0 module.
  present_endpoint_services = var.enable_vpc_endpoints ? keys(module.eks_vpc_endpoints[0].endpoints) : []
}

check "endpoint_set_complete" {
  assert {
    condition     = var.enable_vpc_endpoints && length(setsubtract(local.required_endpoint_services, local.present_endpoint_services)) == 0
    error_message = "the shared VPC is missing required private endpoints: ${join(", ", tolist(setsubtract(local.required_endpoint_services, local.present_endpoint_services)))}. An adopting cluster reaches these over foreign interface endpoints it cannot verify itself — the owner must run the full set (enable_vpc_endpoints = true)."
  }
}

check "consumers_declared" {
  assert {
    condition     = length(var.consumer_account_ids) > 0
    error_message = "consumer_account_ids is empty — a shared-network with no consumers shares its subnets to nobody. Declare the workload account(s) that adopt this VPC, or this is an orphan network."
  }
}

check "role_tags_no_cluster_binding" {
  assert {
    condition = (
      contains(keys(local.public_subnet_role_tags), "kubernetes.io/role/elb") &&
      contains(keys(local.private_subnet_role_tags), "kubernetes.io/role/internal-elb") &&
      alltrue([for k in concat(keys(local.public_subnet_role_tags), keys(local.private_subnet_role_tags)) : !startswith(k, "kubernetes.io/cluster/")])
    )
    error_message = "the shared subnets must carry the ELB role tags and NO kubernetes.io/cluster/<cluster> ownership tag — a shared VPC is bound to no single cluster (see subnet_tags.tf)."
  }
}
