#!/usr/bin/env bash
set -euo pipefail

# Post-apply smoke test for the mode-aware private-dns component. create mode owns private zones in
# the account's own VPC; adopt mode associates a shared Profile with the VPC. Verifies whichever
# the mode produced is live.

DNS_MODE=$(jq -r '.dns_mode.value' outputs.json)
VPC_ID=$(jq -r '.vpc_id.value' outputs.json)

if [[ "$DNS_MODE" == "create" ]]; then
  echo "Checking private zones (create mode) in vpc ${VPC_ID}..."
  ZONE_IDS=$(jq -r '.private_zone_ids.value // {} | to_entries[] | "\(.key) \(.value)"' outputs.json)
  if [[ -z "$ZONE_IDS" ]]; then
    echo "FAIL: create mode declared no private zones"
    exit 1
  fi
  while IFS=' ' read -r ZONE_NAME ZONE_ID; do
    [[ -z "$ZONE_ID" ]] && continue
    IS_PRIVATE=$(aws route53 get-hosted-zone --id "$ZONE_ID" --query 'HostedZone.Config.PrivateZone' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$IS_PRIVATE" == "NOT_FOUND" ]]; then
      echo "FAIL: private zone '${ZONE_NAME}' (${ZONE_ID}) not found"
      exit 1
    fi
    if [[ "$IS_PRIVATE" != "True" ]]; then
      echo "FAIL: zone '${ZONE_NAME}' is not a private hosted zone (PrivateZone=${IS_PRIVATE})"
      exit 1
    fi
    echo "  private zone exists: ${ZONE_NAME} (${ZONE_ID})"
  done <<< "$ZONE_IDS"

elif [[ "$DNS_MODE" == "adopt" ]]; then
  ASSOCIATION_ID=$(jq -r '.association_id.value' outputs.json)
  PROFILE_ID=$(jq -r '.profile_id.value' outputs.json)
  echo "Checking Profile association ${ASSOCIATION_ID} (profile ${PROFILE_ID} -> vpc ${VPC_ID})..."
  ASSOC_STATUS=$(aws route53profiles get-profile-association --profile-association-id "$ASSOCIATION_ID" --query 'ProfileAssociation.Status' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "$ASSOC_STATUS" == "NOT_FOUND" ]]; then
    echo "FAIL: Profile association ${ASSOCIATION_ID} not found"
    exit 1
  fi
  if [[ "$ASSOC_STATUS" != "COMPLETE" ]]; then
    echo "FAIL: association status is '${ASSOC_STATUS}', expected 'COMPLETE'"
    exit 1
  fi
  echo "  Association status: ${ASSOC_STATUS}"

else
  echo "FAIL: unknown dns_mode '${DNS_MODE}'"
  exit 1
fi

echo "PASS: all private-dns checks passed"
