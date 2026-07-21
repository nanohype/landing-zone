#!/usr/bin/env bash
set -euo pipefail

# Parse tenants from outputs
TENANTS=$(jq -r '.tenants.value | keys[]' outputs.json)

if [[ -z "$TENANTS" ]]; then
  echo "No tenants configured, nothing to check"
  echo "PASS: all governance checks passed"
  exit 0
fi

for TENANT in $TENANTS; do
  echo "=== Tenant: ${TENANT} ==="

  # --- S3 Buckets ---
  for BUCKET_KEY in audit_bucket_name guardrail_bucket_name; do
    BUCKET=$(jq -r ".tenants.value[\"${TENANT}\"].${BUCKET_KEY}" outputs.json)
    if [[ -n "$BUCKET" && "$BUCKET" != "null" ]]; then
      echo "Checking ${BUCKET_KEY}..."
      if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
        echo "FAIL: bucket '${BUCKET}' not found"
        exit 1
      fi
      echo "  ${BUCKET_KEY}: exists"
    fi
  done

  # --- KMS Key ---
  KMS_ARN=$(jq -r ".tenants.value[\"${TENANT}\"].audit_kms_key_arn" outputs.json)
  if [[ -n "$KMS_ARN" && "$KMS_ARN" != "null" ]]; then
    echo "Checking audit KMS key..."
    KEY_STATE=$(aws kms describe-key --key-id "$KMS_ARN" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$KEY_STATE" != "Enabled" ]]; then
      echo "FAIL: KMS key state is '${KEY_STATE}'"
      exit 1
    fi
    echo "  KMS key is Enabled"
  fi

  # --- DynamoDB Tables ---
  for TABLE_KEY in audit_table_name cost_table_name; do
    TABLE=$(jq -r ".tenants.value[\"${TENANT}\"].${TABLE_KEY}" outputs.json)
    if [[ -n "$TABLE" && "$TABLE" != "null" ]]; then
      echo "Checking ${TABLE_KEY}..."
      TABLE_STATUS=$(aws dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text 2>/dev/null || echo "NOT_FOUND")
      if [[ "$TABLE_STATUS" != "ACTIVE" ]]; then
        echo "FAIL: DynamoDB table '${TABLE}' status is '${TABLE_STATUS}'"
        exit 1
      fi
      echo "  ${TABLE_KEY}: ACTIVE"
    fi
  done

  # --- EventBridge ---
  EVENT_BUS=$(jq -r ".tenants.value[\"${TENANT}\"].event_bus_name // \"null\"" outputs.json)
  if [[ "$EVENT_BUS" != "null" ]]; then
    echo "Checking EventBridge bus..."
    BUS_ARN=$(aws events describe-event-bus --name "$EVENT_BUS" --query 'Arn' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$BUS_ARN" == "NOT_FOUND" ]]; then
      echo "FAIL: EventBridge bus '${EVENT_BUS}' not found"
      exit 1
    fi
    echo "  EventBridge bus exists"
  fi

  # --- Pod Identity Roles ---
  for ROLE_KEY in audit_writer_role_arn governance_api_role_arn; do
    ROLE_ARN=$(jq -r ".tenants.value[\"${TENANT}\"].${ROLE_KEY}" outputs.json)
    if [[ -n "$ROLE_ARN" && "$ROLE_ARN" != "null" ]]; then
      ROLE_NAME=$(echo "$ROLE_ARN" | awk -F'/' '{print $NF}')
      echo "Checking ${ROLE_KEY}..."
      aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || {
        echo "FAIL: role '${ROLE_NAME}' not found"
        exit 1
      }
      echo "  ${ROLE_KEY}: exists"
    fi
  done
done

echo "PASS: all governance checks passed"
