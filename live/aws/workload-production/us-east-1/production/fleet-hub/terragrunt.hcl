include "root" {
  path = find_in_parent_folders("root.hcl")
}

# The fleet hub, co-located with this environment's workload cluster.
#
# live/aws/fleet/us-east-1/hub/fleet-hub is the OTHER home for this component: a
# dedicated hub account with its own cluster, network and bootstrap. That shape is
# right once an org has one, and unreachable before it does — its `dependency
# "cluster"` resolves ../cluster in the fleet tree, which is a second EKS cluster
# nobody has built yet, and mock outputs stop at plan. So a single-account platform
# could name controlPlane.fleetHubRoleArn and had nothing that could produce it.
#
# This leaf is the same component against the cluster this environment already runs.
# The envcommon's dependency is relative, so it resolves to ../cluster here without
# a copy — and the environment token is this environment's, which is what makes the
# two tenant-boundary wildcards in the hub policy match the clusters it will vend.
#
# ONE PER ACCOUNT. var.state_bucket_name defaults to nanohype-eks-fleet-tfstate and
# carries no account or environment element, by deliberate exception documented on
# the variable: it is the cross-repo bootstrap contract that eks-fleet's
# provider-opentofu backend and rackctl's preflight resolve before any in-cluster
# lookup is possible. A second environment applying this in the same account
# collides on that bucket. That is the intended failure — a fleet hub is a
# singleton, and the collision says so at apply rather than silently vending from
# two control planes.
#
# TEARDOWN. The state bucket and its CMK carry prevent_destroy: they hold every
# vended cluster's tofu state, so a destroy of this root must never take them.
# Emptying the account therefore needs a deliberate act after the destroy, once
# there are no vended clusters left to strand.
include "envcommon" {
  path           = "${dirname(find_in_parent_folders("cloud.hcl"))}/../_envcommon/aws/fleet-hub.hcl"
  merge_strategy = "deep"
}
