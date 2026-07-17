#!/usr/bin/env bash
set -euo pipefail

# Parse outputs
VPC_ID=$(jq -r '.vpc_id.value' outputs.json)
VPC_CIDR=$(jq -r '.vpc_cidr_block.value' outputs.json)
PRIVATE_SUBNETS=$(jq -r '.private_subnet_ids.value[]' outputs.json)
PUBLIC_SUBNETS=$(jq -r '.public_subnet_ids.value[]' outputs.json)
NAT_GW_IDS=$(jq -r '.nat_gateway_ids.value[]' outputs.json)

# --- VPC ---
echo "Checking VPC ${VPC_ID}..."
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

# --- NAT Gateways ---
echo "Checking NAT gateways..."
for NAT_ID in $NAT_GW_IDS; do
  STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" --query 'NatGateways[0].State' --output text)
  if [[ "$STATE" != "available" ]]; then
    echo "FAIL: NAT gateway ${NAT_ID} state is '${STATE}'"
    exit 1
  fi
  echo "  ${NAT_ID} is available"
done

# --- Route Tables ---
echo "Checking private subnet route tables have NAT gateway routes..."
for SUBNET_ID in $PRIVATE_SUBNETS; do
  RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=${SUBNET_ID}" \
    --query 'RouteTables[0].RouteTableId' --output text)
  NAT_ROUTE=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query "RouteTables[0].Routes[?NatGatewayId != null].NatGatewayId" --output text)
  if [[ -z "$NAT_ROUTE" ]]; then
    echo "FAIL: private subnet ${SUBNET_ID} route table ${RT_ID} has no NAT gateway route"
    exit 1
  fi
  echo "  ${SUBNET_ID} -> NAT route present in ${RT_ID}"
done

echo "PASS: all network checks passed"
