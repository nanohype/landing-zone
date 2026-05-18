/**
 * SQS FIFO audit queue + DLQ. The app's audit-logger sends every query /
 * revocation event here; the audit-consumer pod long-polls and writes to
 * DDB + S3.
 *
 * FIFO with content-based dedup so duplicate audit events from a retry
 * don't double-count. MessageGroupId is the userId so per-user events
 * stay ordered without serializing across users.
 */

resource "aws_sqs_queue" "audit_dlq" {
  name                        = "${local.prefix}-audit-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = 1209600 # 14 days
  sqs_managed_sse_enabled     = true

  tags = local.common_tags
}

resource "aws_sqs_queue" "audit" {
  name                        = "${local.prefix}-audit.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = 60
  message_retention_seconds   = 345600 # 4 days
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.audit_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.common_tags
}
