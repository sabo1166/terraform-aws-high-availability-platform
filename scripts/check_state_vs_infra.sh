#!/usr/bin/env bash
# Guard against the most damaging remote-state mistake: pointing Terraform at an EMPTY state while the
# infrastructure already exists (a plan would then say "create everything", and an apply would fail
# on, or duplicate, what is there).
#
# Call this ONLY when `terraform state list` is empty. It looks, read-only, for resources this
# configuration names deterministically. It is a heuristic, not an inventory: it cannot see
# CloudFront, Route 53 records, ACM certificates, SNS topics or alarms.
#
# Usage: check_state_vs_infra.sh <name-prefix, e.g. ha-web-lab> [region]
# Exit 0 = nothing found, 1 = existing infrastructure found, 2 = could not verify (fail closed).
set -uo pipefail

name=${1:?usage: check_state_vs_infra.sh <name-prefix> [region]}
region=${2:-us-east-1}
found=()
unknown=()

# probe <label> <not-found-pattern> <command...>: non-empty output = found; a not-found error = absent;
# any other error (for example AccessDenied) = unknown.
probe() {
  local label=$1 absent=$2 out
  shift 2
  if out=$("$@" 2>&1); then
    [ -n "${out//[[:space:]]/}" ] && [ "$out" != "None" ] && found+=("$label")
  elif [[ $out == *$absent* ]]; then
    :
  else
    unknown+=("$label (${out:0:120})")
  fi
}

probe "VPC ${name}-vpc" "NEVER-MATCHES" \
  aws ec2 describe-vpcs --region "$region" --filters "Name=tag:Name,Values=${name}-vpc" --query 'Vpcs[].VpcId' --output text
probe "RDS instance ${name}-postgres" "DBInstanceNotFound" \
  aws rds describe-db-instances --region "$region" --db-instance-identifier "${name}-postgres" --query 'DBInstances[].DBInstanceIdentifier' --output text
for lb in ext-alb int-alb; do
  probe "load balancer ${name}-${lb}" "LoadBalancerNotFound" \
    aws elbv2 describe-load-balancers --region "$region" --names "${name}-${lb}" --query 'LoadBalancers[].LoadBalancerName' --output text
done
probe "Auto Scaling group ${name}-frontend" "NEVER-MATCHES" \
  aws autoscaling describe-auto-scaling-groups --region "$region" --auto-scaling-group-names "${name}-frontend" --query 'AutoScalingGroups[].AutoScalingGroupName' --output text
probe "IAM role ${name}-frontend" "NoSuchEntity" \
  aws iam get-role --role-name "${name}-frontend" --query 'Role.RoleName' --output text

if [ "${#found[@]}" -gt 0 ]; then
  echo "::error title=Existing infrastructure but empty Terraform state::The state is empty, yet these already exist: ${found[*]}. Planning now would try to create them again. Do NOT continue: locate the existing state (a local terraform.tfstate, another bucket or key) and migrate it, or import the resources. See docs/REMOTE_STATE.md. Nothing was changed."
  exit 1
fi
if [ "${#unknown[@]}" -gt 0 ]; then
  echo "::error title=Cannot verify that no infrastructure exists::The state is empty and these checks failed: ${unknown[*]}. Failing closed. Grant the plan role read access (ReadOnlyAccess) or verify manually. Nothing was changed."
  exit 2
fi
echo "State is empty and no infrastructure named '${name}-*' was found: this looks like a first deployment."
