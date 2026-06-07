/**
 * SQS FIFO queues for incident-response.
 *
 * incident-events: webhook ingress → processor. FIFO because each
 *   incident must dispatch through the war-room assembler exactly once.
 *   MessageGroupId = incident_id, so per-incident messages stay ordered
 *   without serializing across incidents.
 *
 * nudge-events: EventBridge Scheduler fires per-incident 15-min nudges
 *   into here. Same FIFO shape so nudges for the same incident don't
 *   reorder across silence/unsilence cycles.
 *
 * sla-check: scheduled SLA breach checks (P99 assembly > 5min, etc.)
 *   land here. The processor's event registry dispatches to the
 *   appropriate breach handler.
 *
 * Each queue has its own DLQ. maxReceiveCount drives the visibility-
 * timeout retry budget before SQS moves the message to the DLQ.
 */

resource "aws_sqs_queue" "incident_events_dlq" {
  name                        = "${local.prefix}-incident-events-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = var.sqs_message_retention_seconds
  sqs_managed_sse_enabled     = true

  tags = local.common_tags
}

resource "aws_sqs_queue" "incident_events" {
  name                        = "${local.prefix}-incident-events.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = var.sqs_visibility_timeout_seconds
  message_retention_seconds   = var.sqs_message_retention_seconds
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.incident_events_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })

  tags = local.common_tags
}

resource "aws_sqs_queue" "nudge_events_dlq" {
  name                        = "${local.prefix}-nudge-events-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = var.sqs_message_retention_seconds
  sqs_managed_sse_enabled     = true

  tags = local.common_tags
}

resource "aws_sqs_queue" "nudge_events" {
  name                        = "${local.prefix}-nudge-events.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = var.sqs_visibility_timeout_seconds
  message_retention_seconds   = var.sqs_message_retention_seconds
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.nudge_events_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })

  tags = local.common_tags
}

resource "aws_sqs_queue" "sla_check_dlq" {
  name                        = "${local.prefix}-sla-check-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  message_retention_seconds   = var.sqs_message_retention_seconds
  sqs_managed_sse_enabled     = true

  tags = local.common_tags
}

resource "aws_sqs_queue" "sla_check" {
  name                        = "${local.prefix}-sla-check.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = var.sqs_visibility_timeout_seconds
  message_retention_seconds   = var.sqs_message_retention_seconds
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.sla_check_dlq.arn
    maxReceiveCount     = var.sqs_max_receive_count
  })

  tags = local.common_tags
}
