################################################################################
# queue -> SQS (with a dead-letter queue when redrive is set)
################################################################################

locals {
  # FIFO queues must end in ".fifo"; the DLQ mirrors the main queue's type.
  queue_suffix = { for name, d in local.queue_stores : name => d.queue.fifo ? ".fifo" : "" }

  # A DLQ is provisioned only when the datastore sets a redrive budget.
  queues_with_dlq = { for name, d in local.queue_stores : name => d if d.queue.max_receive_count > 0 }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.queues_with_dlq

  name                        = "${local.prefix}-${each.key}-dlq${local.queue_suffix[each.key]}"
  fifo_queue                  = each.value.queue.fifo
  content_based_deduplication = each.value.queue.fifo
  message_retention_seconds   = each.value.queue.message_retention_seconds
  sqs_managed_sse_enabled     = true

  tags = local.data_tags
}

resource "aws_sqs_queue" "queue" {
  for_each = local.queue_stores

  name                        = "${local.prefix}-${each.key}${local.queue_suffix[each.key]}"
  fifo_queue                  = each.value.queue.fifo
  content_based_deduplication = each.value.queue.fifo
  visibility_timeout_seconds  = each.value.queue.visibility_timeout_seconds
  message_retention_seconds   = each.value.queue.message_retention_seconds
  sqs_managed_sse_enabled     = true

  redrive_policy = each.value.queue.max_receive_count > 0 ? jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.queue.max_receive_count
  }) : null

  tags = local.data_tags
}
