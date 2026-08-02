#!/usr/bin/env bash
set -euo pipefail

# Parse outputs
BUDGET_NAME=$(jq -r '.budget_name.value' outputs.json)
ANOMALY_MONITOR_ARN=$(jq -r '.anomaly_monitor_arn.value // "null"' outputs.json)

# --- Budget ---
echo "Checking budget '${BUDGET_NAME}'..."
ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
BUDGET_STATUS=$(aws budgets describe-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" --query 'Budget.BudgetName' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$BUDGET_STATUS" == "NOT_FOUND" ]]; then
  echo "FAIL: budget '${BUDGET_NAME}' not found"
  exit 1
fi
echo "  Budget exists"

# --- Cost Anomaly Monitor ---
if [[ "$ANOMALY_MONITOR_ARN" != "null" ]]; then
  echo "Checking cost anomaly monitor..."
  MONITOR_STATUS=$(aws ce get-anomaly-monitors --monitor-arn-list "$ANOMALY_MONITOR_ARN" --query 'AnomalyMonitors[0].MonitorName' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "$MONITOR_STATUS" == "NOT_FOUND" ]]; then
    echo "FAIL: cost anomaly monitor not found"
    exit 1
  fi
  echo "  Anomaly monitor exists"
else
  echo "Skipping anomaly monitor (not enabled)"
fi

echo "PASS: all cost checks passed"
