/**
 * incident-response-platform — AWS substrate for the incident-response incident-commander
 * tenant. Provisions per-environment DynamoDB tables (incidents + audit +
 * identity-cache), SQS FIFO queues + DLQs (incident-events, nudge-events,
 * sla-check), an S3 audit-archive bucket, the EventBridge Scheduler group
 * + ScheduleRole that the processor pod targets for per-incident 15-min
 * nudges, and the IRSA role the chart's ServiceAccount binds against.
 *
 * Single-tenant on purpose: incident-response's resource shapes (DDB GSI on
 * slack-channel-index, three FIFO queues with specific dedup semantics,
 * EventBridge Scheduler group, etc.) don't generalize cleanly to the
 * other protohype-team apps. Each app gets its own dedicated `<app>-platform`
 * component.
 *
 * Wired by live/_envcommon/aws/incident-response-platform.hcl. Output ARNs flow
 * back into the incident-response Platform CR's spec.irsa.policies via
 * the kx local-config render or whatever bridge the eks-agent-platform
 * operator uses for cross-cluster identity propagation.
 */

locals {
  prefix = "incident-response-${var.environment}"
  tags   = merge({ Component = "incident-response-platform", Tenant = "incident-response" }, var.tags)
}
