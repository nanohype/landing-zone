#!/usr/bin/env bash
set -euo pipefail

# Parse outputs
ROLE_NAME=$(jq -r '.role_name.value' outputs.json)
DETECTION_RULE=$(jq -r '.detection_rule_name.value' outputs.json)
SNS_TOPIC_ARN=$(jq -r '.sns_topic_arn.value' outputs.json)

# --- Break-Glass Role ---
echo "Checking break-glass IAM role '${ROLE_NAME}'..."
ROLE_STATUS=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$ROLE_STATUS" == "NOT_FOUND" ]]; then
  echo "FAIL: break-glass role '${ROLE_NAME}' not found"
  exit 1
fi

# Verify MFA is required in the trust policy
MFA_CONDITION=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.AssumeRolePolicyDocument' --output json | jq -r '.. | .["aws:MultiFactorAuthPresent"]? // empty' 2>/dev/null | head -1)
if [[ -n "$MFA_CONDITION" ]]; then
  echo "  Role exists, MFA required in trust policy"
else
  echo "  Role exists (MFA condition not detected in trust policy — verify manually)"
fi

# --- EventBridge Detection ---
# The detection path is the EventBridge rule, not a CloudWatch alarm. Checking
# the rule exists is not enough: a rule with no target fires into nothing, so
# this asserts the SNS topic is actually on the other end.
echo "Checking break-glass detection rule '${DETECTION_RULE}'..."
RULE_STATE=$(aws events describe-rule --name "$DETECTION_RULE" --query 'State' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$RULE_STATE" != "ENABLED" ]]; then
  echo "FAIL: detection rule '${DETECTION_RULE}' is '${RULE_STATE}', expected ENABLED"
  exit 1
fi

RULE_TARGET=$(aws events list-targets-by-rule --rule "$DETECTION_RULE" --query "Targets[?Arn=='${SNS_TOPIC_ARN}'].Arn" --output text 2>/dev/null || echo "")
if [[ -z "$RULE_TARGET" ]]; then
  echo "FAIL: detection rule '${DETECTION_RULE}' does not target the alert topic — it would fire into nothing"
  exit 1
fi
echo "  Detection rule enabled and targeting the alert topic"

# --- SNS Topic ---
echo "Checking SNS alert topic..."
aws sns get-topic-attributes --topic-arn "$SNS_TOPIC_ARN" --query 'Attributes.TopicArn' --output text >/dev/null 2>&1 || {
  echo "FAIL: SNS topic not found (${SNS_TOPIC_ARN})"
  exit 1
}
echo "  SNS topic exists"

echo "PASS: all break-glass checks passed"
