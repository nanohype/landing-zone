#!/usr/bin/env bash
set -euo pipefail

# Parse outputs
CLUSTER_NAME=$(jq -r '.cluster_name.value' outputs.json)
CLUSTER_ENDPOINT=$(jq -r '.cluster_endpoint.value' outputs.json)
OIDC_PROVIDER_ARN=$(jq -r '.oidc_provider_arn.value' outputs.json)
KARPENTER_QUEUE=$(jq -r '.karpenter_queue_name.value' outputs.json)

# --- EKS Cluster Status ---
echo "Checking EKS cluster ${CLUSTER_NAME}..."
CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.status' --output text)
if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
  echo "FAIL: cluster status is '${CLUSTER_STATUS}', expected 'ACTIVE'"
  exit 1
fi
echo "  Cluster is ACTIVE"

# --- API Endpoint Reachability ---
echo "Checking API endpoint reachability..."
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "${CLUSTER_ENDPOINT}/healthz" || true)
if [[ "$HTTP_CODE" == "000" ]]; then
  echo "FAIL: API endpoint ${CLUSTER_ENDPOINT} is not reachable"
  exit 1
fi
echo "  API endpoint reachable (HTTP ${HTTP_CODE})"

# --- OIDC Provider ---
echo "Checking OIDC provider..."
OIDC_STATUS=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" --query 'Url' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$OIDC_STATUS" == "NOT_FOUND" ]]; then
  echo "FAIL: OIDC provider ${OIDC_PROVIDER_ARN} not found"
  exit 1
fi
echo "  OIDC provider exists: ${OIDC_STATUS}"

# --- Node Groups ---
echo "Checking node groups..."
NODE_GROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --query 'nodegroups[]' --output text)
if [[ -z "$NODE_GROUPS" ]]; then
  echo "  No managed node groups (Karpenter-only cluster)"
else
  for NG in $NODE_GROUPS; do
    NG_STATUS=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG" --query 'nodegroup.status' --output text)
    if [[ "$NG_STATUS" != "ACTIVE" ]]; then
      echo "FAIL: node group ${NG} status is '${NG_STATUS}'"
      exit 1
    fi
    DESIRED=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NG" --query 'nodegroup.scalingConfig.desiredSize' --output text)
    echo "  Node group ${NG} is ACTIVE (desired: ${DESIRED})"
  done
fi

# --- Karpenter SQS Queue ---
echo "Checking Karpenter interruption queue..."
QUEUE_URL=$(aws sqs get-queue-url --queue-name "$KARPENTER_QUEUE" --query 'QueueUrl' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$QUEUE_URL" == "NOT_FOUND" ]]; then
  echo "FAIL: Karpenter SQS queue '${KARPENTER_QUEUE}' not found"
  exit 1
fi
echo "  Queue exists: ${KARPENTER_QUEUE}"

echo "PASS: all cluster checks passed"
