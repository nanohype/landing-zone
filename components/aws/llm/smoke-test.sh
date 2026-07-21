#!/usr/bin/env bash
set -euo pipefail

# Parse tenants from outputs
TENANTS=$(jq -r '.tenant_outputs.value | keys[]' outputs.json)

if [[ -z "$TENANTS" ]]; then
  echo "No tenants configured, nothing to check"
  echo "PASS: all llm checks passed"
  exit 0
fi

for TENANT in $TENANTS; do
  echo "=== Tenant: ${TENANT} ==="

  # --- Model S3 Bucket ---
  MODEL_BUCKET=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].model_bucket_name" outputs.json)
  echo "Checking model bucket..."
  if ! aws s3api head-bucket --bucket "$MODEL_BUCKET" 2>/dev/null; then
    echo "FAIL: model bucket '${MODEL_BUCKET}' not found"
    exit 1
  fi
  echo "  Model bucket exists"

  # --- KMS Key ---
  KMS_ARN=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].model_kms_key_arn" outputs.json)
  if [[ -n "$KMS_ARN" && "$KMS_ARN" != "null" ]]; then
    echo "Checking model KMS key..."
    KEY_STATE=$(aws kms describe-key --key-id "$KMS_ARN" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$KEY_STATE" != "Enabled" ]]; then
      echo "FAIL: KMS key state is '${KEY_STATE}'"
      exit 1
    fi
    echo "  KMS key is Enabled"
  fi

  # --- EFS ---
  EFS_ID=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].efs_filesystem_id" outputs.json)
  if [[ -n "$EFS_ID" && "$EFS_ID" != "null" ]]; then
    echo "Checking EFS filesystem..."
    EFS_STATE=$(aws efs describe-file-systems --file-system-id "$EFS_ID" --query 'FileSystems[0].LifeCycleState' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$EFS_STATE" != "available" ]]; then
      echo "FAIL: EFS '${EFS_ID}' state is '${EFS_STATE}'"
      exit 1
    fi
    echo "  EFS filesystem available"
  fi

  # --- SQS Inference Queue ---
  SQS_URL=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].sqs_inference_queue_url" outputs.json)
  if [[ -n "$SQS_URL" && "$SQS_URL" != "null" ]]; then
    echo "Checking SQS inference queue..."
    aws sqs get-queue-attributes --queue-url "$SQS_URL" --attribute-names QueueArn >/dev/null 2>&1 || {
      echo "FAIL: SQS queue not found (${SQS_URL})"
      exit 1
    }
    echo "  SQS inference queue exists"
  fi

  # --- DynamoDB ---
  DDB_TABLE=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].dynamodb_inference_table" outputs.json)
  if [[ -n "$DDB_TABLE" && "$DDB_TABLE" != "null" ]]; then
    echo "Checking DynamoDB inference table..."
    TABLE_STATUS=$(aws dynamodb describe-table --table-name "$DDB_TABLE" --query 'Table.TableStatus' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$TABLE_STATUS" != "ACTIVE" ]]; then
      echo "FAIL: DynamoDB table '${DDB_TABLE}' status is '${TABLE_STATUS}'"
      exit 1
    fi
    echo "  DynamoDB table ACTIVE"
  fi

  # --- ECR ---
  ECR_URI=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].ecr_repository_uri // \"null\"" outputs.json)
  if [[ "$ECR_URI" != "null" ]]; then
    REPO_NAME=$(echo "$ECR_URI" | awk -F'/' '{print $NF}')
    echo "Checking ECR repository..."
    aws ecr describe-repositories --repository-names "$REPO_NAME" >/dev/null 2>&1 || {
      echo "FAIL: ECR repository '${REPO_NAME}' not found"
      exit 1
    }
    echo "  ECR repository exists"
  fi

  # --- Pod Identity Roles ---
  for ROLE_KEY in inference_server_role_arn api_gateway_role_arn; do
    ROLE_ARN=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].${ROLE_KEY}" outputs.json)
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

echo "PASS: all llm checks passed"
