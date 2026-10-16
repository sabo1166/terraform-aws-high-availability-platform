#!/usr/bin/env bash
# Read-only check that an S3 bucket is fit to hold Terraform state: reachable, versioned (so an
# older state can be restored), with every public-access block on and default encryption present.
# Usage: check_state_bucket.sh <bucket> [bucket-region]     Exit 0 = fit, 1 = not fit / cannot verify.
set -uo pipefail

bucket=${1:?usage: check_state_bucket.sh <bucket> [bucket-region]}
region=${2:-us-east-1}
fail=0
problem() { echo "::error title=State bucket '$bucket'::$*"; fail=1; }

err=$(aws s3api head-bucket --bucket "$bucket" --region "$region" 2>&1 >/dev/null) || {
  case "$err" in
    *404* | *"Not Found"* | *NoSuchBucket*) problem "bucket does not exist in $region. Create it first (docs/REMOTE_STATE.md); Terraform will not create its own state bucket." ;;
    *403* | *Forbidden* | *AccessDenied*) problem "bucket is not accessible with these credentials (403). Check the role's s3:ListBucket permission and that the bucket is in $region." ;;
    *) problem "cannot reach the bucket: ${err:0:200}" ;;
  esac
  exit 1
}

versioning=$(aws s3api get-bucket-versioning --bucket "$bucket" --region "$region" --query Status --output text 2>/dev/null || true)
[ "$versioning" = "Enabled" ] || problem "versioning is not enabled (status: ${versioning:-none}). Without it a bad apply or an accidental delete of the state cannot be undone."

pab=$(aws s3api get-public-access-block --bucket "$bucket" --region "$region" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
  --output text 2>/dev/null || true)
read -r a b c d <<<"$pab"
if [ "${a:-}${b:-}${c:-}${d:-}" != "TrueTrueTrueTrue" ]; then
  problem "the four S3 Block Public Access settings are not all enabled (got: ${pab:-none}). State can contain secrets; the bucket must be private."
fi

aws s3api get-bucket-encryption --bucket "$bucket" --region "$region" >/dev/null 2>&1 \
  || problem "no default encryption configuration was returned for the bucket."

if [ "$fail" -ne 0 ]; then
  echo "State bucket '$bucket' is NOT fit to hold Terraform state. Nothing was changed."
  exit 1
fi
echo "State bucket '$bucket' ($region): reachable, versioned, public access blocked, encrypted by default."
