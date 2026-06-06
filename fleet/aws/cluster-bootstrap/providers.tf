# The post-cluster bootstrap root: agent-iam (AWS) + cluster-bootstrap (k8s/helm),
# run by a provider-opentofu Workspace AFTER the cluster is Ready. Sibling to
# cluster-stack — it lands in its own root because it pulls the k8s/helm/kubectl
# providers (the provider-boundary split the single-root decision allows).
#
# Only the AWS provider is configured here. The cluster-bootstrap component
# self-configures kubernetes/helm/kubectl/github from the cluster endpoint + CA
# inputs (its k8s auth is `aws eks get-token`, run as this root's AWS identity);
# both wrapped modules inherit this default AWS provider.
#
# assume_role is the cross-account hinge for the AWS-side work (agent-iam's role +
# the data sources): empty = same-account (the hub's own identity), set = the
# workload account's vend role, presenting external_id (the fleet-vend trust
# requires sts:ExternalId).
#
# NOTE: this assume_role covers AWS calls only. The component's `aws eks get-token`
# uses ambient creds, so it reaches the spoke API only when the runner already has
# cluster access. Same-account: the hub is the cluster creator (admin via
# enable_cluster_creator_admin_permissions) — works. Cross-account: needs a
# cluster-admin EKS access entry for the hub role (tracked separately).
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Environment   = var.environment
      ManagedBy     = "opentofu"
      Project       = "landing-zone"
      ProvisionedBy = "eks-fleet"
      Team          = var.team
    }
  }

  dynamic "assume_role" {
    for_each = var.assume_role_arn != "" ? [1] : []
    content {
      role_arn    = var.assume_role_arn
      external_id = var.external_id
    }
  }
}
