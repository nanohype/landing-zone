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
  # us-east-1 is the one region that must NOT carry a LocationConstraint. It is
  # S3's implicit default, and CreateBucket rejects a request naming it with
  # InvalidLocationConstraint — so the unconditional form fails in exactly the
  # region every tree in this repo deploys into, on the documented first step of
  # standing up an account.
  if [ "${REGION}" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}"
  else
    aws s3api create-bucket \
      --bucket "${BUCKET}" \
      --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi

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
