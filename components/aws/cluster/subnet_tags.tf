# Per-cluster subnet ownership tag on the shared, env-scoped VPC.
#
# The network component provisions one VPC per environment and is cluster-agnostic:
# it tags subnets only with the kubernetes.io/role/* ELB-scheduling tags. Each cluster
# stamps its own kubernetes.io/cluster/<cluster>: shared ownership tag here — the cluster
# is in the tag KEY, so co-located sibling clusters coexist on the same shared subnets
# with no collision. Both the AWS load-balancer controller (ELB subnet discovery) and
# each cluster's Karpenter EC2NodeClass (subnetSelectorTerms) select on this tag.
#
# karpenter.sh/discovery is deliberately NOT applied to subnets: it's a single key with
# the cluster in the VALUE, so two co-located siblings tagging the same shared subnet
# would collide (last-write-wins, and the loser's Karpenter finds no subnets). Karpenter's
# node-SG selection uses karpenter.sh/discovery on the PER-CLUSTER node security group
# (see cluster/eks.tf) — a per-cluster resource, so no sharing and no collision there.
#
# stamp_subnet_tags gates this off in the cross-account adopt topology: a participant
# cannot write a tag on a subnet owned by another account (a RAM-shared subnet), so the
# network owner (shared-network) owns subnet tagging there. In create mode (default) the
# cluster owns or co-shares an in-account VPC and stamps its own ownership tag here.

resource "aws_ec2_tag" "subnet_cluster_ownership" {
  for_each = var.stamp_subnet_tags ? toset(concat(var.private_subnet_ids, var.public_subnet_ids)) : toset([])

  resource_id = each.value
  key         = "kubernetes.io/cluster/${local.cluster_name}"
  value       = "shared"
}
