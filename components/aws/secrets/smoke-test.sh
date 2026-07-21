#!/usr/bin/env bash
set -euo pipefail

# Parse outputs
KMS_KEY_ARN=$(jq -r '.kms_key_arn.value' outputs.json)
KMS_KEY_ID=$(jq -r '.kms_key_id.value' outputs.json)
KMS_ALIAS_ARN=$(jq -r '.kms_alias_arn.value' outputs.json)

# This component owns encryption and storage only. The external-secrets identity is a
# cluster-addons role (a ServiceAccount holds exactly one EKS Pod Identity association, so
# every addon role lives there), and cluster-addons' own smoke test asserts it. There is no
# role to check here.

# --- KMS Key ---
echo "Checking secrets KMS key..."
KEY_STATE=$(aws kms describe-key --key-id "$KMS_KEY_ID" --query 'KeyMetadata.KeyState' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$KEY_STATE" != "Enabled" ]]; then
  echo "FAIL: KMS key state is '${KEY_STATE}', expected 'Enabled'"
  exit 1
fi
echo "  KMS key is Enabled"

# --- KMS Alias ---
# Consumers reference the alias, not the raw key id, so the alias has to resolve to the
# key this component created rather than to some other key of the same name.
echo "Checking secrets KMS alias..."
ALIAS_TARGET=$(aws kms describe-key --key-id "$KMS_ALIAS_ARN" --query 'KeyMetadata.Arn' --output text 2>/dev/null || echo "NOT_FOUND")
if [[ "$ALIAS_TARGET" != "$KMS_KEY_ARN" ]]; then
  echo "FAIL: KMS alias resolves to '${ALIAS_TARGET}', expected '${KMS_KEY_ARN}'"
  exit 1
fi
echo "  KMS alias resolves to the secrets key"

# --- Secrets ---
echo "Checking Secrets Manager secrets..."
SECRETS=$(jq -r '.secret_arns.value // {} | to_entries[] | "\(.key) \(.value)"' outputs.json)
SECRET_NAMES=$(jq -r '.secret_names.value // {} | to_entries[] | "\(.key) \(.value)"' outputs.json)
if [[ -n "$SECRETS" ]]; then
  while IFS=' ' read -r SECRET_KEY SECRET_ARN; do
    # Name and KmsKeyId in one call: the secret has to exist, be the one this component
    # named, and be encrypted with this component's customer-managed key.
    SECRET_DESC=$(aws secretsmanager describe-secret --secret-id "$SECRET_ARN" --query '[Name,KmsKeyId]' --output text 2>/dev/null || echo "NOT_FOUND")
    if [[ "$SECRET_DESC" == "NOT_FOUND" ]]; then
      echo "FAIL: secret '${SECRET_KEY}' not found (${SECRET_ARN})"
      exit 1
    fi
    read -r ACTUAL_NAME SECRET_KMS <<< "$SECRET_DESC"

    EXPECTED_NAME=$(awk -v k="$SECRET_KEY" '$1 == k { print $2 }' <<< "$SECRET_NAMES")
    if [[ "$ACTUAL_NAME" != "$EXPECTED_NAME" ]]; then
      echo "FAIL: secret '${SECRET_KEY}' is named '${ACTUAL_NAME}', expected '${EXPECTED_NAME}'"
      exit 1
    fi

    # DescribeSecret echoes back whatever form the key was set in; accept the ARN this
    # component passes and the bare key id, reject any other key.
    if [[ "$SECRET_KMS" != "$KMS_KEY_ARN" && "$SECRET_KMS" != "$KMS_KEY_ID" ]]; then
      echo "FAIL: secret '${SECRET_KEY}' is encrypted with '${SECRET_KMS}', expected the platform secrets key"
      exit 1
    fi
    echo "  ${SECRET_KEY}: exists as '${ACTUAL_NAME}', encrypted with the secrets key"
  done <<< "$SECRETS"
else
  echo "  No secrets configured"
fi

echo "PASS: all secrets checks passed"
