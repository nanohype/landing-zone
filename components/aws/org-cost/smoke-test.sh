#!/usr/bin/env bash
set -euo pipefail

# Parse outputs
BUDGET_NAME=$(jq -r '.budget_name.value' outputs.json)
ANOMALY_MONITOR_SERVICE=$(jq -r '.anomaly_monitor_service_arn.value // "null"' outputs.json)
ANOMALY_MONITOR_ACCOUNT=$(jq -r '.anomaly_monitor_account_arn.value // "null"' outputs.json)
CUR_BUCKET=$(jq -r '.cur_export_bucket_name.value // "null"' outputs.json)
CUR_EXPORT_NAME=$(jq -r '.cur_export_name.value // "null"' outputs.json)
CUR_EXPORT_PREFIX=$(jq -r '.cur_export_prefix.value // "null"' outputs.json)

# --- Org Budget ---
echo "Checking org budget '${BUDGET_NAME}'..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
BUDGET_STATUS=$(aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" --query 'Budget.BudgetName' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$BUDGET_STATUS" == "NOT_FOUND" ]]; then
  echo "FAIL: org budget '${BUDGET_NAME}' not found"
  exit 1
fi
echo "  Org budget exists"

# --- Cost Anomaly Monitors ---
for MONITOR_LABEL in "service:${ANOMALY_MONITOR_SERVICE}" "account:${ANOMALY_MONITOR_ACCOUNT}"; do
  LABEL=${MONITOR_LABEL%%:*}
  ARN=${MONITOR_LABEL#*:}
  if [[ "$ARN" != "null" ]]; then
    echo "Checking cost anomaly monitor (${LABEL})..."
    MONITOR_NAME=$(aws ce get-anomaly-monitors --monitor-arn-list "$ARN" --query 'AnomalyMonitors[0].MonitorName' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$MONITOR_NAME" == "NOT_FOUND" ]]; then
      echo "FAIL: cost anomaly monitor (${LABEL}) not found"
      exit 1
    fi
    echo "  ${LABEL} monitor exists: ${MONITOR_NAME}"
  fi
done

# --- Cost Categories ---
echo "Checking cost categories..."
CATEGORIES=$(jq -r '.cost_category_arns.value // {} | to_entries[] | "\(.key) \(.value)"' outputs.json)
if [[ -n "$CATEGORIES" ]]; then
  while IFS=' ' read -r CAT_NAME CAT_ARN; do
    CAT_STATUS=$(aws ce describe-cost-category-definition --cost-category-arn "$CAT_ARN" --query 'CostCategory.Name' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$CAT_STATUS" == "NOT_FOUND" ]]; then
      echo "FAIL: cost category '${CAT_NAME}' not found"
      exit 1
    fi
    echo "  ${CAT_NAME}: exists"
  done <<< "$CATEGORIES"
else
  echo "  No cost categories configured"
fi

# --- CUR Export Bucket ---
if [[ "$CUR_BUCKET" != "null" ]]; then
  echo "Checking CUR export bucket..."
  if ! aws s3api head-bucket --bucket "$CUR_BUCKET" 2>/dev/null; then
    echo "FAIL: CUR export bucket '${CUR_BUCKET}' not found"
    exit 1
  fi
  echo "  CUR export bucket exists"
fi

# --- CUR 2.0 Export ---
#
# The bucket existing says nothing about the export. What matters is the export's own
# configuration, read back from the service: an export can be HEALTHY, delivering on
# schedule, into the right bucket, and still be missing the one table configuration that
# makes its data answerable — and nothing about that is visible from S3.
#
# Data Exports is a global service reached through us-east-1; the ARN is always
# us-east-1 regardless of where this component is applied.
if [[ "$CUR_EXPORT_NAME" != "null" ]]; then
  echo "Checking CUR 2.0 export '${CUR_EXPORT_NAME}'..."
  EXPORT_ARN=$(aws bcm-data-exports list-exports --region us-east-1 \
    --query "Exports[?ExportName=='${CUR_EXPORT_NAME}'].ExportArn | [0]" --output text 2>/dev/null || echo "None")
  if [[ "$EXPORT_ARN" == "None" || -z "$EXPORT_ARN" ]]; then
    echo "FAIL: CUR 2.0 export '${CUR_EXPORT_NAME}' not found"
    exit 1
  fi
  echo "  export exists: ${EXPORT_ARN}"

  EXPORT_JSON=$(aws bcm-data-exports get-export --export-arn "$EXPORT_ARN" --region us-east-1 --output json)

  # The assertion this whole component turns on. A Bedrock model invocation is not a
  # taggable resource, so no resourceTags/ column is ever populated on one; caller
  # identity is the only attribution AWS offers, and this table configuration is the
  # only thing that produces it. Absent, every per-platform cost query returns zero
  # rows and exits zero.
  IAM_PRINCIPAL=$(jq -r '.Export.DataQuery.TableConfigurations.COST_AND_USAGE_REPORT.INCLUDE_IAM_PRINCIPAL_DATA // "ABSENT"' <<<"$EXPORT_JSON")
  if [[ "$IAM_PRINCIPAL" != "TRUE" ]]; then
    echo "FAIL: export '${CUR_EXPORT_NAME}' has INCLUDE_IAM_PRINCIPAL_DATA=${IAM_PRINCIPAL}"
    echo "  Without it there is no line_item_iam_principal column and no iamPrincipal/* tag"
    echo "  columns, so Amazon Bedrock spend cannot be attributed to any platform and every"
    echo "  budget's billed leg reads zero through a query that succeeds."
    exit 1
  fi
  echo "  caller-identity allocation data is on"

  # And it delivers where the contract says it does. A prefix mismatch produces a table
  # with no partitions rather than an error.
  ACTUAL_PREFIX=$(jq -r '.Export.DestinationConfigurations.S3Destination.S3Prefix // "ABSENT"' <<<"$EXPORT_JSON")
  if [[ "$ACTUAL_PREFIX" != "$CUR_EXPORT_PREFIX" ]]; then
    echo "FAIL: export delivers under '${ACTUAL_PREFIX}' but the contract publishes '${CUR_EXPORT_PREFIX}'"
    echo "  A consumer crawling the published prefix finds no objects, registers a table with"
    echo "  no partitions, and every query against it returns nothing without erroring."
    exit 1
  fi
  echo "  delivers under the published prefix '${ACTUAL_PREFIX}'"
fi

echo "PASS: all org-cost checks passed"
