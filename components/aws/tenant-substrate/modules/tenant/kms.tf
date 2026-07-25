################################################################################
# Per-tenant customer-managed key
################################################################################
#
# One CMK per tenant, minted whether or not the tenant declares a datastore. The
# key is the tenant's own cryptographic boundary, and two consumers already need
# it to be tenant-scoped rather than shared:
#
#   1. Envelope encryption in the application. A tenant storing per-user OAuth
#      tokens calls GenerateDataKey/Decrypt directly. The agent-iam baseline
#      cannot serve that: its only KMS grant is scoped to the model-artifacts key
#      AND conditioned on kms:ViaService = s3, so a direct call is denied even on
#      the key it names. Without a tenant key there is nothing to grant on except
#      a hand-written policy through extraPolicyArns — the escape hatch the
#      datastore vocabulary exists to remove.
#
#   2. The RDS-managed master secret. Encrypting it with the tenant's own key
#      means a cross-tenant read fails at decrypt even if an IAM statement is
#      ever over-broad again — defence in depth behind the exact-ARN scoping the
#      operator applies.
#
# The operator grants GenerateDataKey/Decrypt/DescribeKey on this ARN and nothing
# else, so one tenant's key is unusable by another regardless of what their
# policies say.
#
# Deliberately NOT re-keyed onto here: the object stores (SSE-S3) and Aurora
# storage (the AWS-managed RDS key). Both are already encrypted at rest, moving
# them is a replace-and-restore rather than an edit, and neither is reached by a
# direct KMS call from application code. Scope this key to what actually needs a
# tenant-owned key today.

resource "aws_kms_key" "tenant" {
  description = "Tenant-owned key for ${local.prefix} — application envelope encryption and the RDS-managed master secret"

  # Rotation is free correctness here: nothing pins a key version, and both
  # consumers resolve the key by ARN.
  enable_key_rotation = true

  # Long enough that an accidental destroy is recoverable through a support
  # window, short enough that a real teardown completes in a sprint.
  deletion_window_in_days = 30

  tags = merge(local.tenant_tags, { Name = "${local.prefix}-tenant" })
}

resource "aws_kms_alias" "tenant" {
  name          = "alias/${local.prefix}-tenant"
  target_key_id = aws_kms_key.tenant.key_id
}
