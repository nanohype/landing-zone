#!/usr/bin/env bash
set -euo pipefail

# Creates the S3 bucket for Terraform state.
# Usage: ./scripts/init-backend-aws.sh <account_id> <region>

ACCOUNT_ID="${1:?Usage: init-backend-aws.sh <account_id> <region>}"
REGION="${2:?Usage: init-backend-aws.sh <account_id> <region>}"
BUCKET="${ACCOUNT_ID}-${REGION}-tfstate"

echo "Creating S3 bucket: ${BUCKET}"
if aws s3api head-bucket --bucket "${BUCKET}" 2>/dev/null; then
  echo "Bucket already exists."
else
  aws s3api create-bucket \
    --bucket "${BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"

  aws s3api put-bucket-versioning \
    --bucket "${BUCKET}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "${BUCKET}" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        },
        "BucketKeyEnabled": true
      }]
    }'

  aws s3api put-public-access-block \
    --bucket "${BUCKET}" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  echo "Bucket created and configured."
fi

echo "Backend infrastructure ready."
