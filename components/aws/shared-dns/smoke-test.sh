#!/usr/bin/env bash
set -euo pipefail

# Post-apply smoke test for the shared-dns owner component. Verifies the Route53 Profile, its
# attached private zones, and the RAM share are live — the owner-side half of the private-DNS
# contract a consuming account depends on.

PROFILE_ID=$(jq -r '.profile_id.value' outputs.json)
RAM_SHARE_ARN=$(jq -r '.ram_share_arn.value // empty' outputs.json)
ZONE_NAMES=$(jq -r '.private_zone_names.value[]' outputs.json)

# --- Profile ---
echo "Checking Route53 Profile ${PROFILE_ID}..."
PROFILE_STATUS=$(aws route53profiles get-profile --profile-id "$PROFILE_ID" --query 'Profile.Status' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$PROFILE_STATUS" == "NOT_FOUND" ]]; then
  echo "FAIL: Profile ${PROFILE_ID} not found"
  exit 1
fi
echo "  Profile status: ${PROFILE_STATUS}"

# --- Zone attachments ---
echo "Checking zone attachments on the Profile..."
ATTACHED=$(aws route53profiles list-profile-resource-associations --profile-id "$PROFILE_ID" --query "ProfileResourceAssociations[?ResourceType=='PRIVATE_HOSTED_ZONE'] | length(@)" --output text 2>/dev/null || echo "0")
echo "  Private hosted zones attached: ${ATTACHED}"
if [[ "$ATTACHED" == "0" ]]; then
  echo "FAIL: Profile carries no private hosted zones — nothing would resolve for consumers"
  exit 1
fi
while IFS= read -r ZONE; do
  [[ -z "$ZONE" ]] && continue
  echo "  declared zone: ${ZONE}"
done <<< "$ZONE_NAMES"

# --- RAM share ---
if [[ -n "$RAM_SHARE_ARN" ]]; then
  echo "Checking RAM share ${RAM_SHARE_ARN}..."
  SHARE_STATUS=$(aws ram get-resource-shares --resource-owner SELF --resource-share-arns "$RAM_SHARE_ARN" --query 'resourceShares[0].status' --output text 2>/dev/null || echo "NOT_FOUND")
  if [[ "$SHARE_STATUS" != "ACTIVE" ]]; then
    echo "FAIL: RAM share status is '${SHARE_STATUS}', expected 'ACTIVE'"
    exit 1
  fi
  echo "  RAM share status: ${SHARE_STATUS}"
else
  echo "Skipping RAM share (no consumers declared)"
fi

echo "PASS: all shared-dns checks passed"
