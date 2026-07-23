#!/usr/bin/env bash
set -euo pipefail

# Post-apply smoke test for the private-dns participant component. Verifies the Profile is
# associated with the cluster VPC and the association is live — the consumer-side half of the
# private-DNS contract.

ASSOCIATION_ID=$(jq -r '.association_id.value' outputs.json)
PROFILE_ID=$(jq -r '.profile_id.value' outputs.json)
VPC_ID=$(jq -r '.vpc_id.value' outputs.json)

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

echo "PASS: all private-dns checks passed"
