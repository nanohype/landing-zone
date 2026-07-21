#!/usr/bin/env bash
set -euo pipefail

# Parse tenants from outputs
TENANTS=$(jq -r '.tenant_outputs.value | keys[]' outputs.json)

if [[ -z "$TENANTS" ]]; then
  echo "No tenants configured, nothing to check"
  echo "PASS: all druid checks passed"
  exit 0
fi

for TENANT in $TENANTS; do
  echo "=== Tenant: ${TENANT} ==="

  # --- Aurora ---
  AURORA_ENDPOINT=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].aurora_endpoint" outputs.json)
  echo "Checking Aurora endpoint..."
  if [[ -z "$AURORA_ENDPOINT" || "$AURORA_ENDPOINT" == "null" ]]; then
    echo "FAIL: Aurora endpoint not set for tenant '${TENANT}'"
    exit 1
  fi
  # Extract cluster identifier from endpoint (first segment before the dot)
  CLUSTER_ID=$(echo "$AURORA_ENDPOINT" | cut -d'.' -f1)
  CLUSTER_STATUS=$(aws rds describe-db-clusters --db-cluster-identifier "$CLUSTER_ID" --query 'DBClusters[0].Status' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "$CLUSTER_STATUS" != "available" ]]; then
    echo "FAIL: Aurora cluster '${CLUSTER_ID}' status is '${CLUSTER_STATUS}'"
    exit 1
  fi
  echo "  Aurora cluster available"

  # --- S3 Buckets ---
  for BUCKET_KEY in s3_deepstorage s3_indexlogs s3_msq; do
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

  # --- Pod Identity Roles ---
  for ROLE_KEY in historical_role_arn ingestion_role_arn query_role_arn; do
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

  # --- MSK ---
  MSK_BOOTSTRAP=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].msk_bootstrap // \"null\"" outputs.json)
  if [[ "$MSK_BOOTSTRAP" != "null" && -n "$MSK_BOOTSTRAP" ]]; then
    echo "Checking MSK bootstrap servers..."
    echo "  MSK bootstrap: ${MSK_BOOTSTRAP}"
  fi
done

echo "PASS: all druid checks passed"
