#!/usr/bin/env bash
set -euo pipefail

# Parse tenants from outputs
TENANTS=$(jq -r '.tenants.value | keys[]' outputs.json)

if [[ -z "$TENANTS" ]]; then
  echo "No tenants configured, nothing to check"
  echo "PASS: all mlops checks passed"
  exit 0
fi

for TENANT in $TENANTS; do
  echo "=== Tenant: ${TENANT} ==="

  # --- S3 Buckets ---
  for BUCKET_KEY in datasets_bucket_name artifacts_bucket_name; do
    BUCKET=$(jq -r ".tenants.value[\"${TENANT}\"].${BUCKET_KEY}" outputs.json)
    echo "Checking ${BUCKET_KEY}..."
    if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
      echo "FAIL: bucket '${BUCKET}' not found"
      exit 1
    fi
    echo "  ${BUCKET_KEY}: exists"
  done

  # --- KMS Key ---
  KMS_ARN=$(jq -r ".tenants.value[\"${TENANT}\"].kms_key_arn" outputs.json)
  echo "Checking KMS key..."
  KEY_STATE=$(aws kms describe-key --key-id "$KMS_ARN" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "$KEY_STATE" != "Enabled" ]]; then
    echo "FAIL: KMS key state is '${KEY_STATE}'"
    exit 1
  fi
  echo "  KMS key is Enabled"

  # --- DynamoDB Tables ---
  for TABLE_KEY in experiments_table_name model_registry_table_name; do
    TABLE=$(jq -r ".tenants.value[\"${TENANT}\"].${TABLE_KEY}" outputs.json)
    echo "Checking ${TABLE_KEY}..."
    TABLE_STATUS=$(aws dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$TABLE_STATUS" != "ACTIVE" ]]; then
      echo "FAIL: DynamoDB table '${TABLE}' status is '${TABLE_STATUS}'"
      exit 1
    fi
    echo "  ${TABLE_KEY}: ACTIVE"
  done

  # --- SQS Queues ---
  TRAINING_QUEUE_URL=$(jq -r ".tenants.value[\"${TENANT}\"].training_queue_url" outputs.json)
  echo "Checking training queue..."
  aws sqs get-queue-attributes --queue-url "$TRAINING_QUEUE_URL" --attribute-names QueueArn >/dev/null 2>&1 || {
    echo "FAIL: training queue not found"
    exit 1
  }
  echo "  Training queue exists"

  DLQ_URL=$(jq -r ".tenants.value[\"${TENANT}\"].training_dlq_url" outputs.json)
  echo "Checking training DLQ..."
  aws sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn >/dev/null 2>&1 || {
    echo "FAIL: training DLQ not found"
    exit 1
  }
  echo "  Training DLQ exists"

  # --- ECR ---
  ECR_URI=$(jq -r ".tenants.value[\"${TENANT}\"].ecr_repository_uri // \"null\"" outputs.json)
  if [[ "$ECR_URI" != "null" && -n "$ECR_URI" ]]; then
    REPO_NAME=$(echo "$ECR_URI" | awk -F'/' '{print $NF}')
    echo "Checking ECR repository..."
    aws ecr describe-repositories --repository-names "$REPO_NAME" >/dev/null 2>&1 || {
      echo "FAIL: ECR repository '${REPO_NAME}' not found"
      exit 1
    }
    echo "  ECR repository exists"
  fi

  # --- Pod Identity Roles ---
  for ROLE_KEY in training_worker_role_arn model_registry_role_arn mlops_api_role_arn; do
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

echo "PASS: all mlops checks passed"
