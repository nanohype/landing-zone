#!/usr/bin/env bash
set -euo pipefail

# Parse tenants from outputs
TENANTS=$(jq -r '.tenant_outputs.value | keys[]' outputs.json)

if [[ -z "$TENANTS" ]]; then
  echo "No tenants configured, nothing to check"
  echo "PASS: all gateway checks passed"
  exit 0
fi

for TENANT in $TENANTS; do
  echo "=== Tenant: ${TENANT} ==="

  REST_API_ID=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].rest_api_id" outputs.json)
  REST_API_ENDPOINT=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].rest_api_endpoint" outputs.json)
  USER_POOL_ID=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].user_pool_id // \"null\"" outputs.json)
  WAF_ACL_ARN=$(jq -r ".tenant_outputs.value[\"${TENANT}\"].waf_acl_arn // \"null\"" outputs.json)

  # --- API Gateway ---
  echo "Checking API Gateway..."
  API_NAME=$(aws apigateway get-rest-api --rest-api-id "$REST_API_ID" --query 'name' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "$API_NAME" == "NOT_FOUND" ]]; then
    echo "FAIL: REST API '${REST_API_ID}' not found"
    exit 1
  fi
  echo "  REST API exists: ${API_NAME}"

  # Verify endpoint is reachable
  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "${REST_API_ENDPOINT}" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "000" ]]; then
    echo "  API endpoint not reachable (may require VPN/VPC access)"
  else
    echo "  API endpoint reachable (HTTP ${HTTP_CODE})"
  fi

  # --- Cognito User Pool ---
  if [[ "$USER_POOL_ID" != "null" ]]; then
    echo "Checking Cognito user pool..."
    POOL_STATUS=$(aws cognito-idp describe-user-pool --user-pool-id "$USER_POOL_ID" --query 'UserPool.Status' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$POOL_STATUS" == "NOT_FOUND" ]]; then
      echo "FAIL: Cognito user pool '${USER_POOL_ID}' not found"
      exit 1
    fi
    echo "  User pool exists (status: ${POOL_STATUS})"
  fi

  # --- WAF ---
  if [[ "$WAF_ACL_ARN" != "null" ]]; then
    echo "Checking WAF web ACL..."
    WAF_NAME=$(aws wafv2 get-web-acl --name "$(echo "$WAF_ACL_ARN" | awk -F'/' '{print $(NF-1)}')" --scope REGIONAL --id "$(echo "$WAF_ACL_ARN" | awk -F'/' '{print $NF}')" --query 'WebACL.Name' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$WAF_NAME" == "NOT_FOUND" ]]; then
      echo "FAIL: WAF web ACL not found"
      exit 1
    fi
    echo "  WAF web ACL exists: ${WAF_NAME}"
  fi
done

echo "PASS: all gateway checks passed"
