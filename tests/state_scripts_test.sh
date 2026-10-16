#!/usr/bin/env bash
# Unit tests for scripts/check_state_bucket.sh and scripts/check_state_vs_infra.sh using a fake `aws`
# executable, so no AWS account, credentials or network are involved.
# Usage: bash tests/state_scripts_test.sh
set -u

here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/aws" <<'FAKE'
#!/usr/bin/env bash
# Fake AWS CLI. Behavior is driven by FAKE_* environment variables.
deny() { echo "An error occurred (AccessDenied) when calling the operation: Access Denied" >&2; exit 254; }
case "$1 $2" in
  "s3api head-bucket")
    case "${FAKE_BUCKET:-ok}" in missing) echo "An error occurred (404) when calling the HeadBucket operation: Not Found" >&2; exit 254 ;;
      forbidden) echo "An error occurred (403) when calling the HeadBucket operation: Forbidden" >&2; exit 254 ;; esac ;;
  "s3api get-bucket-versioning") echo "${FAKE_VERSIONING:-Enabled}" ;;
  "s3api get-public-access-block")
    case "${FAKE_PAB:-all}" in none) echo "NoSuchPublicAccessBlockConfiguration" >&2; exit 254 ;;
      partial) printf 'True\tTrue\tTrue\tFalse\n' ;; *) printf 'True\tTrue\tTrue\tTrue\n' ;; esac ;;
  "s3api get-bucket-encryption") [ "${FAKE_ENC:-yes}" = yes ] || { echo "ServerSideEncryptionConfigurationNotFoundError" >&2; exit 254; } ;;
  "ec2 describe-vpcs") if [ -n "${FAKE_DENY:-}" ]; then deny; fi; if [ "${FAKE_INFRA:-none}" = vpc ]; then echo vpc-0123456789; fi ;;
  "rds describe-db-instances") if [ -n "${FAKE_DENY:-}" ]; then deny; fi; if [ "${FAKE_INFRA:-none}" = rds ]; then echo ha-web-lab-postgres; else echo "An error occurred (DBInstanceNotFound)" >&2; exit 254; fi ;;
  "elbv2 describe-load-balancers") if [ -n "${FAKE_DENY:-}" ]; then deny; fi; echo "An error occurred (LoadBalancerNotFound)" >&2; exit 254 ;;
  "autoscaling describe-auto-scaling-groups") if [ -n "${FAKE_DENY:-}" ]; then deny; fi ;;
  "iam get-role") if [ -n "${FAKE_DENY:-}" ]; then deny; fi; echo "An error occurred (NoSuchEntity)" >&2; exit 254 ;;
  *) echo "fake aws: unexpected call: $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$tmp/aws"
export PATH="$tmp:$PATH"

pass=0
failed=0
expect() { # description, expected exit code, command...
  local desc=$1 want=$2 got
  shift 2
  "$@" >/dev/null 2>&1
  got=$?
  if [ "$got" -eq "$want" ]; then pass=$((pass + 1)); else failed=$((failed + 1)); echo "FAIL: $desc (expected exit $want, got $got)"; fi
}
bucket() { bash "$here/scripts/check_state_bucket.sh" b us-east-1; }
infra() { bash "$here/scripts/check_state_vs_infra.sh" ha-web-lab us-east-1; }

# --- bucket fitness
expect "fit bucket passes" 0 bucket
FAKE_BUCKET=missing expect "missing bucket fails" 1 bucket
FAKE_BUCKET=forbidden expect "inaccessible bucket fails" 1 bucket
FAKE_VERSIONING=Suspended expect "suspended versioning fails" 1 bucket
FAKE_VERSIONING=None expect "no versioning fails" 1 bucket
FAKE_PAB=none expect "no public access block fails" 1 bucket
FAKE_PAB=partial expect "partial public access block fails" 1 bucket
FAKE_ENC=no expect "no default encryption fails" 1 bucket

# --- existing infrastructure vs empty state
expect "nothing exists: first deployment passes" 0 infra
FAKE_INFRA=vpc expect "existing VPC with empty state is refused" 1 infra
FAKE_INFRA=rds expect "existing database with empty state is refused" 1 infra
FAKE_DENY=1 expect "cannot verify: fails closed" 2 infra

echo "state script tests: $pass passed, $failed failed"
[ "$failed" -eq 0 ]
