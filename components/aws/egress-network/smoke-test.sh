#!/usr/bin/env bash
set -euo pipefail

# Post-apply smoke test for the egress hub. Verifies the VPC, its NAT gateways, the TGW
# attachment, and the spoke return route are live — the data path a centralized-egress spoke
# depends on. The static 0.0.0.0/0 route that steers spoke default egress here lives in the
# TGW owner (org-networking), so it is verified from that component, not this one.

VPC_ID=$(jq -r '.vpc_id.value' outputs.json)
VPC_CIDR=$(jq -r '.vpc_cidr.value' outputs.json)
PRIVATE_SUBNETS=$(jq -r '.private_subnet_ids.value[]' outputs.json)
NAT_GATEWAYS=$(jq -r '.nat_gateway_ids.value[]' outputs.json)
TGW_ATTACHMENT_ID=$(jq -r '.tgw_attachment_id.value' outputs.json)
PUBLIC_RTBS=$(jq -r '.public_route_table_ids.value[]' outputs.json)
SPOKE_SUPERNET_CIDR=$(jq -r '.spoke_supernet_cidr.value' outputs.json)

# --- VPC ---
echo "Checking egress VPC ${VPC_ID}..."
VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].State' --output text)
if [[ "$VPC_STATE" != "available" ]]; then
  echo "FAIL: VPC state is '${VPC_STATE}', expected 'available'"
  exit 1
fi
echo "  VPC is available (CIDR: ${VPC_CIDR})"

# --- NAT gateways ---
echo "Checking NAT gateways..."
for NAT_ID in $NAT_GATEWAYS; do
  STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_ID" --query 'NatGateways[0].State' --output text)
  if [[ "$STATE" != "available" ]]; then
    echo "FAIL: NAT gateway ${NAT_ID} state is '${STATE}', expected 'available'"
    exit 1
  fi
  echo "  ${NAT_ID} available"
done

# --- TGW attachment ---
echo "Checking TGW attachment ${TGW_ATTACHMENT_ID}..."
ATTACH_STATE=$(aws ec2 describe-transit-gateway-vpc-attachments \
  --transit-gateway-attachment-ids "$TGW_ATTACHMENT_ID" \
  --query 'TransitGatewayVpcAttachments[0].State' --output text)
if [[ "$ATTACH_STATE" != "available" ]]; then
  echo "FAIL: TGW attachment state is '${ATTACH_STATE}', expected 'available' — the owner TGW (org-networking) must have auto_accept_shared_attachments enabled and the TGW must be RAM-shared to this account"
  exit 1
fi
echo "  TGW attachment is available"

# --- Spoke return route on the public route tables ---
# Verify the specific spoke-return route: a route whose destination is exactly
# spoke_supernet_cidr and whose target is the transit gateway. Querying by destination (not
# "any TGW-bound route") is what makes this assert the return path actually exists — a route
# table could carry an unrelated TGW route and still be missing the spoke return.
echo "Checking the spoke return route (${SPOKE_SUPERNET_CIDR} -> TGW) on every public route table..."
for RT_ID in $PUBLIC_RTBS; do
  RETURN_ROUTE_TGW=$(aws ec2 describe-route-tables \
    --route-table-ids "$RT_ID" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='${SPOKE_SUPERNET_CIDR}'].TransitGatewayId | [0]" --output text)
  if [[ -z "$RETURN_ROUTE_TGW" || "$RETURN_ROUTE_TGW" == "None" ]]; then
    echo "FAIL: public route table ${RT_ID} has no ${SPOKE_SUPERNET_CIDR} -> TGW return route — NAT-translated replies cannot reach the spokes"
    exit 1
  fi
  echo "  ${RT_ID} carries the spoke return route ${SPOKE_SUPERNET_CIDR} -> ${RETURN_ROUTE_TGW}"
done

echo "PASS: all egress-network checks passed"
