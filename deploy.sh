#!/usr/bin/env bash
#
# deploy.sh - Deploy the cross-region S3 Object Lock + Replication stacks.
#
# Deploys THREE stacks in order:
#   1. destination-stack-us-west-1.yaml  (us-west-1)
#   2. replication-role.yaml             (us-west-2)
#   3. source-stack-us-west-2.yaml       (us-west-2)
#
# The role is its own stack (step 2) so it has a real ARN before the source
# stack runs, and before you grant that ARN on any existing KMS key you
# bring in. See replication-role.yaml for why.
#
# By default, stacks 1 and 2 each create their own dedicated KMS key. If you
# already have customer-managed KMS keys you want to use instead, pass their
# ARNs as the optional 5th and 6th arguments; leave them blank ("") to let
# each stack create its own key as before.
#
# If you bring your own SOURCE key (6th argument) and want that key's policy
# scoped to the replication role specifically, rather than to account root,
# this script PAUSES after deploying the role stack and prints the role's
# real ARN, so you can grant it on your existing key before the source stack
# runs. Press Enter to continue once you've done that, or once you've
# confirmed your key's policy already grants what it needs (for example, if
# it already grants account root).
#
# Usage:
#   ./deploy.sh <source-bucket-name> <destination-bucket-name> \
#               <source-logging-bucket-name> <destination-logging-bucket-name> \
#               [retention-mode] [retention-days] \
#               [existing-destination-kms-key-arn] [existing-source-kms-key-arn] \
#               [replication-role-name]
#
# The source-logging-bucket and destination-logging-bucket are REQUIRED. Each
# must be an existing S3 bucket, in the same Region as the bucket it logs
# (source-logging-bucket in us-west-2, destination-logging-bucket in
# us-west-1), and must NOT have Object Lock enabled (S3 does not allow an
# Object Lock bucket to be a server access logging destination).
#
# Examples:
#   # Let both stacks create their own KMS keys (default behavior).
#   ./deploy.sh amzn-s3-demo-source-uswest2 amzn-s3-demo-dest-uswest1 \
#       amzn-s3-demo-logs-uswest2 amzn-s3-demo-logs-uswest1 GOVERNANCE 30
#
#   # Bring your own KMS keys for both buckets. The script will pause before
#   # the source stack so you can grant the role's real ARN on your existing
#   # source key first.
#   ./deploy.sh amzn-s3-demo-source-uswest2 amzn-s3-demo-dest-uswest1 \
#       amzn-s3-demo-logs-uswest2 amzn-s3-demo-logs-uswest1 GOVERNANCE 30 \
#       arn:aws:kms:us-west-1:111122223333:key/dest-key-id \
#       arn:aws:kms:us-west-2:111122223333:key/source-key-id
#
#   # Same, with a specific replication role name.
#   ./deploy.sh amzn-s3-demo-source-uswest2 amzn-s3-demo-dest-uswest1 \
#       amzn-s3-demo-logs-uswest2 amzn-s3-demo-logs-uswest1 GOVERNANCE 30 \
#       arn:aws:kms:us-west-1:111122223333:key/dest-key-id \
#       arn:aws:kms:us-west-2:111122223333:key/source-key-id \
#       my-org-s3-replication-role
#
# Requirements: AWS CLI v2 configured with credentials for the target account.
# If you bring your own keys, their key policies must grant kms:Encrypt,
# kms:Decrypt, and kms:GenerateDataKey to whoever needs them (account root,
# or the replication role's ARN, printed by this script after step 2).
# This script requests CAPABILITY_NAMED_IAM for the role stack unconditionally,
# so both custom-name and auto-generated-name cases work.

set -euo pipefail

# --------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------
SOURCE_BUCKET="${1:?Usage: ./deploy.sh <source-bucket> <destination-bucket> <source-logging-bucket> <destination-logging-bucket> [mode] [days] [existing-dest-kms-arn] [existing-source-kms-arn] [replication-role-name]}"
DEST_BUCKET="${2:?Usage: ./deploy.sh <source-bucket> <destination-bucket> <source-logging-bucket> <destination-logging-bucket> [mode] [days] [existing-dest-kms-arn] [existing-source-kms-arn] [replication-role-name]}"
SOURCE_LOGGING_BUCKET="${3:?A source-region (us-west-2) server access logging bucket is required. It must be an existing bucket WITHOUT Object Lock.}"
DEST_LOGGING_BUCKET="${4:?A destination-region (us-west-1) server access logging bucket is required. It must be an existing bucket WITHOUT Object Lock.}"
RETENTION_MODE="${5:-GOVERNANCE}"
RETENTION_DAYS="${6:-30}"
EXISTING_DEST_KMS_KEY_ARN="${7:-}"
EXISTING_SOURCE_KMS_KEY_ARN="${8:-}"
REPLICATION_ROLE_NAME="${9:-}"

# --------------------------------------------------------------------------
# Fixed config (edit if your regions/stack names differ)
# --------------------------------------------------------------------------
DEST_REGION="us-west-1"
SOURCE_REGION="us-west-2"
DEST_STACK="s3-objlock-destination"
ROLE_STACK="s3-objlock-replication-role"
SOURCE_STACK="s3-objlock-source"
DEST_TEMPLATE="destination-stack-us-west-1.yaml"
ROLE_TEMPLATE="replication-role.yaml"
SOURCE_TEMPLATE="source-stack-us-west-2.yaml"

echo "==> [1/3] Deploying DESTINATION stack '${DEST_STACK}' in ${DEST_REGION}..."
if [[ -n "${EXISTING_DEST_KMS_KEY_ARN}" ]]; then
  echo "    Using existing destination KMS key: ${EXISTING_DEST_KMS_KEY_ARN}"
fi
aws cloudformation deploy \
  --template-file "${DEST_TEMPLATE}" \
  --stack-name "${DEST_STACK}" \
  --region "${DEST_REGION}" \
  --parameter-overrides \
      DestinationBucketName="${DEST_BUCKET}" \
      LoggingBucketName="${DEST_LOGGING_BUCKET}" \
      RetentionMode="${RETENTION_MODE}" \
      RetentionDays="${RETENTION_DAYS}" \
      ExistingKmsKeyArn="${EXISTING_DEST_KMS_KEY_ARN}"

echo "==> Reading destination stack outputs..."
DEST_KMS_KEY_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${DEST_STACK}" \
  --region "${DEST_REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='DestinationKmsKeyArn'].OutputValue" \
  --output text)

DEST_BUCKET_OUT=$(aws cloudformation describe-stacks \
  --stack-name "${DEST_STACK}" \
  --region "${DEST_REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='DestinationBucketName'].OutputValue" \
  --output text)

if [[ -z "${DEST_KMS_KEY_ARN}" || "${DEST_KMS_KEY_ARN}" == "None" ]]; then
  echo "ERROR: could not read DestinationKmsKeyArn from ${DEST_STACK}." >&2
  exit 1
fi

echo "    DestinationBucketName = ${DEST_BUCKET_OUT}"
echo "    DestinationKmsKeyArn  = ${DEST_KMS_KEY_ARN}"

echo "==> [2/3] Deploying REPLICATION ROLE stack '${ROLE_STACK}' in ${SOURCE_REGION}..."
if [[ -n "${EXISTING_SOURCE_KMS_KEY_ARN}" ]]; then
  echo "    Using existing source KMS key: ${EXISTING_SOURCE_KMS_KEY_ARN}"
fi
if [[ -n "${REPLICATION_ROLE_NAME}" ]]; then
  echo "    Using custom replication role name: ${REPLICATION_ROLE_NAME}"
fi
aws cloudformation deploy \
  --template-file "${ROLE_TEMPLATE}" \
  --stack-name "${ROLE_STACK}" \
  --region "${SOURCE_REGION}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
      SourceBucketName="${SOURCE_BUCKET}" \
      DestinationBucketName="${DEST_BUCKET_OUT}" \
      DestinationKmsKeyArn="${DEST_KMS_KEY_ARN}" \
      DestinationRegion="${DEST_REGION}" \
      ExistingSourceKmsKeyArn="${EXISTING_SOURCE_KMS_KEY_ARN}" \
      ReplicationRoleName="${REPLICATION_ROLE_NAME}"

echo "==> Reading replication role stack outputs..."
ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${ROLE_STACK}" \
  --region "${SOURCE_REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ReplicationRoleArn'].OutputValue" \
  --output text)

SOURCE_KMS_KEY_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${ROLE_STACK}" \
  --region "${SOURCE_REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='SourceKmsKeyArn'].OutputValue" \
  --output text)

if [[ -z "${ROLE_ARN}" || "${ROLE_ARN}" == "None" ]]; then
  echo "ERROR: could not read ReplicationRoleArn from ${ROLE_STACK}." >&2
  exit 1
fi

echo "    ReplicationRoleArn = ${ROLE_ARN}"
echo "    SourceKmsKeyArn    = ${SOURCE_KMS_KEY_ARN}"

# --------------------------------------------------------------------------
# If an existing source key was supplied, pause here so the caller can grant
# the role's real ARN on it before the source bucket (and replication) exist.
# --------------------------------------------------------------------------
if [[ -n "${EXISTING_SOURCE_KMS_KEY_ARN}" ]]; then
  echo ""
  echo "==> You brought your own source KMS key: ${EXISTING_SOURCE_KMS_KEY_ARN}"
  echo "    The replication role now exists with a real ARN:"
  echo "        ${ROLE_ARN}"
  echo ""
  echo "    Before continuing, confirm that key's policy grants kms:Encrypt,"
  echo "    kms:Decrypt, and kms:GenerateDataKey to either account root, or"
  echo "    specifically to the role ARN above. If it does not yet, grant it"
  echo "    now (for example, via 'aws kms put-key-policy' or the console),"
  echo "    then press Enter to continue to the source stack."
  read -r -p "    Press Enter once the key policy is ready: " _
fi

echo "==> [3/3] Deploying SOURCE stack '${SOURCE_STACK}' in ${SOURCE_REGION}..."
aws cloudformation deploy \
  --template-file "${SOURCE_TEMPLATE}" \
  --stack-name "${SOURCE_STACK}" \
  --region "${SOURCE_REGION}" \
  --parameter-overrides \
      SourceBucketName="${SOURCE_BUCKET}" \
      LoggingBucketName="${SOURCE_LOGGING_BUCKET}" \
      DestinationBucketName="${DEST_BUCKET_OUT}" \
      DestinationKmsKeyArn="${DEST_KMS_KEY_ARN}" \
      SourceKmsKeyArn="${SOURCE_KMS_KEY_ARN}" \
      ReplicationRoleArn="${ROLE_ARN}" \
      RetentionMode="${RETENTION_MODE}" \
      RetentionDays="${RETENTION_DAYS}"

echo "==> Done. Source (${SOURCE_REGION}) now replicates to destination (${DEST_REGION})."
