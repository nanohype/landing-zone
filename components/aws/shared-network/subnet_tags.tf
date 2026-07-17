# Owner-side subnet role tags — the cluster-agnostic tagging convention.
#
# Public subnets get kubernetes.io/role/elb; private subnets get
# kubernetes.io/role/internal-elb. These are the ELB scheduling hints the AWS Load Balancer
# Controller reads to place internet-facing vs internal load balancers. They are applied
# through the VPC module's public_subnet_tags / private_subnet_tags (see main.tf), which
# tags the module's own subnets — the plan-safe path, since an aws_ec2_tag for_each over
# subnet IDs the module hasn't created yet cannot resolve its keys at plan.
#
# There is deliberately NO kubernetes.io/cluster/<cluster> ownership tag here, and that
# omission IS the contract:
#   - A shared VPC is owned by no single cluster. Binding it to one cluster's ownership tag
#     would be wrong, and the co-located-sibling trick the same-account cluster component
#     uses (cluster in the tag KEY) does not survive RAM sharing — a participant cannot
#     write a tag on a subnet it does not own, so it could never add its own key anyway.
#   - Cross-account consumers therefore select subnets by explicit ID (the adopt_* inputs),
#     never by discovery tag. AWS RAM does not surface owner-written tags to participants,
#     so a cluster ownership tag would be invisible to them regardless.
# The role tags below exist for same-account participants that discover by tag and as the
# owner's own authoritative, auditable convention on the shared subnets.

locals {
  public_subnet_role_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_role_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}
