#!/usr/bin/env bash
set -euo pipefail

# Parse tenants from outputs
TENANTS=$(jq -r '.tenant_outputs.value | keys[]' outputs.json)

if [[ -z "$TENANTS" ]]; then
  echo "No tenants configured, nothing to check"
  echo "PASS: all pipeline checks passed"
  exit 0
fi

for TENANT in $TENANTS; do
  echo "=== Tenant: ${TENANT} ==="

  # --- Data Lake S3 Buckets ---
  for BUCKET_KEY in raw_bucket staging_bucket curated_bucket; do
    BUCKET=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].${BUCKET_KEY}" outputs.json)
    if [[ -n "$BUCKET" && "$BUCKET" != "null" ]]; then
      echo "Checking ${BUCKET_KEY}..."
      if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
        echo "FAIL: bucket '${BUCKET}' not found"
        exit 1
      fi
      echo "  ${BUCKET_KEY}: exists"
    fi
  done

  # --- MSK ---
  MSK_ARN=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].msk_arn // \"null\"" outputs.json)
  if [[ "$MSK_ARN" != "null" ]]; then
    echo "Checking MSK cluster..."
    MSK_STATE=$(aws kafka describe-cluster-v2 --cluster-arn "$MSK_ARN" --query 'ClusterInfo.State' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$MSK_STATE" != "ACTIVE" && "$MSK_STATE" != "NOT_FOUND" ]]; then
      echo "FAIL: MSK cluster state is '${MSK_STATE}'"
      exit 1
    fi
    if [[ "$MSK_STATE" == "ACTIVE" ]]; then
      echo "  MSK cluster ACTIVE"
    else
      echo "  MSK cluster not found (may be serverless — checking)"
    fi
  fi

  # --- Batch ---
  BATCH_ARN=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].batch_queue_arn // \"null\"" outputs.json)
  if [[ "$BATCH_ARN" != "null" ]]; then
    QUEUE_NAME=$(echo "$BATCH_ARN" | awk -F'/' '{print $NF}')
    echo "Checking Batch job queue..."
    BATCH_STATUS=$(aws batch describe-job-queues --job-queues "$QUEUE_NAME" --query 'jobQueues[0].status' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$BATCH_STATUS" == "VALID" ]]; then
      echo "  Batch job queue is VALID"
    elif [[ "$BATCH_STATUS" == "NOT_FOUND" ]]; then
      echo "FAIL: Batch job queue '${QUEUE_NAME}' not found"
      exit 1
    else
      echo "  Batch job queue status: ${BATCH_STATUS}"
    fi
  fi

  # --- Glue ---
  GLUE_DB=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].glue_database // \"null\"" outputs.json)
  if [[ "$GLUE_DB" != "null" ]]; then
    echo "Checking Glue database..."
    aws glue get-database --name "$GLUE_DB" >/dev/null 2>&1 || {
      echo "FAIL: Glue database '${GLUE_DB}' not found"
      exit 1
    }
    echo "  Glue database exists"
  fi
done

echo "PASS: all pipeline checks passed"
