#!/usr/bin/env bash
set -euo pipefail

# Post-apply smoke test for the shared-network owner component. Verifies the shared VPC, its
# subnets, the private endpoint set, and the RAM share are live — the owner-side half of the
# adopt contract a consuming account depends on.

VPC_ID=$(jq -r '.vpc_id.value' outputs.json)
VPC_CIDR=$(jq -r '.vpc_cidr_block.value' outputs.json)
PRIVATE_SUBNETS=$(jq -r '.private_subnet_ids.value[]' outputs.json)
PUBLIC_SUBNETS=$(jq -r '.public_subnet_ids.value[]' outputs.json)
RAM_SHARE_ARN=$(jq -r '.ram_share_arn.value // empty' outputs.json)
CONSUMER_ACCOUNTS=$(jq -r '.consumer_account_ids.value[]' outputs.json)

# --- VPC ---
echo "Checking shared VPC ${VPC_ID}..."
VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].State' --output text)
if [[ "$VPC_STATE" != "available" ]]; then
  echo "FAIL: VPC state is '${VPC_STATE}', expected 'available'"
  exit 1
fi
echo "  VPC is available (CIDR: ${VPC_CIDR})"

# --- Subnets ---
echo "Checking private subnets..."
for SUBNET_ID in $PRIVATE_SUBNETS; do
  STATE=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].State' --output text)
  AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].AvailabilityZone' --output text)
  if [[ "$STATE" != "available" ]]; then
    echo "FAIL: private subnet ${SUBNET_ID} state is '${STATE}'"
    exit 1
  fi
  echo "  ${SUBNET_ID} available in ${AZ}"
done

echo "Checking public subnets..."
for SUBNET_ID in $PUBLIC_SUBNETS; do
  STATE=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].State' --output text)
  AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].AvailabilityZone' --output text)
  if [[ "$STATE" != "available" ]]; then
    echo "FAIL: public subnet ${SUBNET_ID} state is '${STATE}'"
    exit 1
  fi
  echo "  ${SUBNET_ID} available in ${AZ}"
done

# --- S3 gateway endpoint route (the participant-observable half of the contract) ---
echo "Checking every private route table carries the S3 gateway prefix-list route..."
S3_PL=$(aws ec2 describe-prefix-lists \
  --filters "Name=prefix-list-name,Values=com.amazonaws.$(aws configure get region).s3" \
  --query 'PrefixLists[0].PrefixListId' --output text)
for SUBNET_ID in $PRIVATE_SUBNETS; do
  RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=${SUBNET_ID}" \
    --query 'RouteTables[0].RouteTableId' --output text)
  S3_ROUTE=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query "RouteTables[0].Routes[?DestinationPrefixListId=='${S3_PL}'].DestinationPrefixListId" --output text)
  if [[ -z "$S3_ROUTE" ]]; then
    echo "FAIL: private subnet ${SUBNET_ID} route table ${RT_ID} has no S3 gateway route (${S3_PL})"
    exit 1
  fi
  echo "  ${SUBNET_ID} -> S3 gateway route present in ${RT_ID}"
done

# --- RAM share ---
if [[ -n "$RAM_SHARE_ARN" ]]; then
  echo "Checking RAM share ${RAM_SHARE_ARN}..."
  SHARE_STATUS=$(aws ram get-resource-shares \
    --resource-owner SELF --resource-share-arns "$RAM_SHARE_ARN" \
    --query 'resourceShares[0].status' --output text)
  if [[ "$SHARE_STATUS" != "ACTIVE" ]]; then
    echo "FAIL: RAM share status is '${SHARE_STATUS}', expected 'ACTIVE'"
    exit 1
  fi
  echo "  RAM share is ACTIVE"

  # An ACTIVE share is not the same as a resolved share. If org-wide resource sharing is not
  # enabled in AWS Organizations, a principal association to another org account is accepted
  # but never resolves (it sits FAILED / ASSOCIATING) while the share itself still reports
  # ACTIVE — the exact "silently never resolves" failure the README's activation section
  # warns about. Check each configured consumer's PRINCIPAL association actually reached
  # ASSOCIATED, not just that the share exists.
  echo "Checking each consumer's RAM principal association resolved..."
  for ACCT in $CONSUMER_ACCOUNTS; do
    ASSOC_STATUS=$(aws ram get-resource-share-associations \
      --association-type PRINCIPAL \
      --resource-share-arns "$RAM_SHARE_ARN" \
      --principal "$ACCT" \
      --query 'resourceShareAssociations[0].status' --output text)
    if [[ "$ASSOC_STATUS" != "ASSOCIATED" ]]; then
      echo "FAIL: consumer ${ACCT} principal association is '${ASSOC_STATUS}', expected 'ASSOCIATED' — the share is ACTIVE but this association never resolved. Enable resource sharing with AWS Organizations (aws ram enable-sharing-with-aws-organizations) and confirm ${ACCT} is in the owner's organization."
      exit 1
    fi
    echo "  ${ACCT} -> principal association ASSOCIATED"
  done
else
  echo "No RAM share (consumer_account_ids empty) — skipping share check"
fi

echo "PASS: all shared-network checks passed"
