# Remote state

Terraform state for this stack lives in a private, versioned S3 bucket. This file covers the design, how to create the bucket, the IAM permissions, how to migrate existing state, and recovery.

**Status:** designed and tested locally against a local S3 emulator (moto) and a fake AWS CLI. **No state bucket exists yet, nothing has been migrated, and no real AWS call was made.** Items that need a real bucket are listed at the end.

## Design

| Piece | Choice | Why |
|---|---|---|
| Backend | S3, declared in the committed `backend.tf` | One source of truth for local use and CI. CI's `validate` sees the real backend block. |
| Configuration | **Partial**: `bucket`, `key`, `region` passed at `terraform init` | Backend blocks cannot reference variables, and no bucket name is committed. |
| Locking | `use_lockfile = true` (lock object `<key>.tflock` in the same bucket) | Native S3 locking needs Terraform ≥ 1.10 (this repo pins 1.16.2). **DynamoDB locking is deprecated** by Terraform, so no table is created or needed. |
| Encryption | `encrypt = true` plus the bucket's default encryption | State holds secrets (for example the CloudFront origin-verify header). |
| State key | `ha-web/lab/terraform.tfstate` (default) | One key per environment. If you change `project_name` or `environment`, use a different key; resource names would change. |
| Region | the region **of the bucket** (`us-east-1` by default) | Independent of the stack's region. |
| Workspaces | only `default` | CI fails on any other workspace. |

GitHub repository variables read by CI: `TF_STATE_BUCKET` (**required**), `TF_STATE_KEY` (optional), `TF_STATE_REGION` (optional). All AWS-backed workflow jobs go through one action, `.github/actions/terraform-backend`, so plan, apply and destroy cannot disagree. There is no local-state or empty-state path in CI.

Local use:

```bash
cp backend.tfbackend.example backend.tfbackend     # git-ignored; set bucket, key, region
terraform init -backend-config=backend.tfbackend
```

Throwaway experiments without a bucket: create an untracked `override.tf` containing `terraform { backend "local" {} }`. Never use local state for CI or a shared stack.

## What CI refuses to do

Before any plan, apply or destroy, the action:

1. **Requires `TF_STATE_BUCKET`** and validates the bucket name and key. No variable means a clear failure, not a fallback.
2. **Checks the bucket** (`scripts/check_state_bucket.sh`, read-only): reachable, **versioning enabled**, all four **Block Public Access** settings on, default encryption present.
3. Runs `terraform init -lockfile=readonly` against the S3 backend and checks the workspace is `default`.
4. **If the state is empty, checks that the infrastructure does not already exist** (`scripts/check_state_vs_infra.sh`): the VPC, database, load balancers, frontend Auto Scaling group and an IAM role named `<project>-<env>-*`. If any exist, it stops with "Existing infrastructure but empty Terraform state" and explains. If it cannot tell (for example `AccessDenied`) it **fails closed**.

This guard is a heuristic. It cannot see CloudFront, Route 53 records, ACM certificates, SNS or alarms, so it reduces the chance of planning against existing infrastructure; it does not prove there is none.

## Is there existing state?

Evidence at the time of writing:

- No `terraform.tfstate`, `.tfstate.backup` or plan file exists in the repository directory, and the backend was never initialised locally.
- Every GitHub Actions run so far skipped the apply job and no plan artifact was ever uploaded, so CI cannot have created anything.
- AWS could not be queried (the available credentials are invalid), so a manual apply from another machine **cannot be ruled out**. Check before the first CI run:

```bash
find ~ -name 'terraform.tfstate*' -not -path '*/.terraform/*' 2>/dev/null     # any local state on this machine
aws s3 ls | grep -i -E 'tfstate|terraform|state'                              # candidate state buckets
aws ec2 describe-vpcs --filters Name=tag:Name,Values=ha-web-lab-vpc --query 'Vpcs[].VpcId'
aws rds describe-db-instances --query 'DBInstances[?starts_with(DBInstanceIdentifier, `ha-web-lab`)].DBInstanceIdentifier'
```

If any of those finds something, follow **Migrate existing state** below instead of creating a fresh bucket key.

## Create the bucket (once, outside this stack)

Not run by anyone yet. Choose a globally unique name; keep the bucket out of this Terraform stack so a `destroy` can never delete the state.

```bash
B=<globally-unique-bucket-name>; R=us-east-1
aws s3api create-bucket --bucket "$B" --region "$R"            # outside us-east-1 add: --create-bucket-configuration LocationConstraint=$R
aws s3api put-bucket-ownership-controls --bucket "$B" --ownership-controls 'Rules=[{ObjectOwnership=BucketOwnerEnforced}]'
aws s3api put-public-access-block --bucket "$B" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$B" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$B" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-lifecycle-configuration --bucket "$B" --lifecycle-configuration '{"Rules":[{"ID":"expire-old-state-versions","Status":"Enabled","Filter":{},"NoncurrentVersionExpiration":{"NoncurrentDays":90,"NewerNoncurrentVersions":20},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":7}}]}'
aws s3api put-bucket-policy --bucket "$B" --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"DenyInsecureTransport\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::$B\",\"arn:aws:s3:::$B/*\"],\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}"
```

Then set the GitHub variable `TF_STATE_BUCKET` (and `TF_STATE_REGION` if the bucket is not in `us-east-1`). The lifecycle rule keeps the 20 most recent old versions for at least 90 days; tune it to how far back you want to be able to roll back. SSE-S3 is used for simplicity; with SSE-KMS the roles also need `kms:Decrypt`/`kms:GenerateDataKey` on that key.

## IAM permissions for state

Derived from the S3 requests Terraform actually made against a local S3 emulator for each operation:

| Operation | S3 requests |
|---|---|
| `init`, `state list`, `console`, `plan -lock=false` | `ListBucket` on the bucket; `GET`/`HEAD` on the state object. **No writes, no lock object.** |
| `plan` / `apply` with locking | additionally `PUT`, `GET`, `DELETE` on `<key>.tflock` |
| `apply` | additionally `PUT` (new state version) on the state object |
| the bucket check in CI | `HeadBucket` (needs `s3:ListBucket`), `GetBucketVersioning`, `GetBucketPublicAccessBlock`, `GetEncryptionConfiguration` |

`s3:ListBucket` cannot be restricted with an `s3:prefix` condition, because `HeadBucket` sends no prefix and would be denied; use a dedicated state bucket instead.

**Plan role** (read-only; CI plans with `-lock=false`). Attach alongside the AWS-managed `ReadOnlyAccess` policy, which already covers the infrastructure reads and the bucket-posture reads, or use this alone for state access:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketVersioning", "s3:GetBucketPublicAccessBlock", "s3:GetEncryptionConfiguration"],
      "Resource": "arn:aws:s3:::BUCKET" },
    { "Effect": "Allow", "Action": "s3:GetObject", "Resource": "arn:aws:s3:::BUCKET/ha-web/lab/terraform.tfstate" }
  ]
}
```

**Apply / destroy role**, state portion (its infrastructure permissions are separate; see `GITHUB_ACTIONS.md`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketVersioning", "s3:GetBucketPublicAccessBlock", "s3:GetEncryptionConfiguration"],
      "Resource": "arn:aws:s3:::BUCKET" },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject"], "Resource": "arn:aws:s3:::BUCKET/ha-web/lab/terraform.tfstate" },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], "Resource": "arn:aws:s3:::BUCKET/ha-web/lab/terraform.tfstate.tflock" }
  ]
}
```

No role needs `s3:DeleteObject` on the state object itself, `s3:*`, or access to other prefixes. Because the empty-state guard reads `ec2`, `rds`, `elbv2`, `autoscaling` and `iam`, the apply role's infrastructure policy must allow those reads too (the plan role gets them from `ReadOnlyAccess`). **These policies were never evaluated by AWS.** The permission list comes from observed behavior of Terraform's S3 backend (emulated), not from an IAM simulation.

## Migrate existing state

Never overwrite or discard an existing state. Work on a copy first and keep the original until a CI plan has succeeded.

1. **Find the state** (see "Is there existing state?"). Confirm it is the right one: `terraform state list` against it should list this stack's resources; note the count and the `serial` (`grep '"serial"' terraform.tfstate`).
2. **Make sure nothing else is running** (no local apply, no CI run).
3. **Back it up** outside the repository and record a checksum:
   ```bash
   cp terraform.tfstate ~/tfstate-backup-$(date +%Y%m%d-%H%M).tfstate && sha256sum ~/tfstate-backup-*.tfstate
   ```
4. **Create and verify the bucket** (above), then `cp backend.tfbackend.example backend.tfbackend` and fill it in.
5. **Migrate**:
   ```bash
   terraform init -migrate-state -backend-config=backend.tfbackend     # answer "yes" to copy the existing state
   ```
   A plain `terraform init` with existing local state **refuses** to continue non-interactively instead of silently creating an empty remote state (rehearsed). Terraform leaves an emptied `terraform.tfstate` and a `terraform.tfstate.backup`.
6. **Verify before trusting it**:
   ```bash
   terraform state list | wc -l                                              # same count as before
   aws s3api list-object-versions --bucket "$B" --prefix ha-web/lab/        # the object exists
   terraform plan                                                            # must say "No changes"
   ```
   If the plan wants to **create everything**, stop: the wrong state was migrated. Restore from your backup.
7. Set `TF_STATE_BUCKET` (and `TF_STATE_KEY`/`TF_STATE_REGION` if non-default) and run the workflow. Keep your backup until a CI plan is clean.

**State already in another S3 location**: with the old backend still configured in `.terraform/`, run `terraform init -migrate-state` with the new `-backend-config`. Otherwise pull then push: `terraform state pull > old.tfstate`, init the new backend, `terraform state push old.tfstate`.

**Infrastructure exists but no state can be found**: do not apply. Either import each resource with `terraform import`, or accept replacing the infrastructure. Importing a stack this size is slow; check old backups and other machines first.

## Recovery

| Situation | Action |
|---|---|
| A bad apply wrote a broken state | `aws s3api list-object-versions --bucket "$B" --prefix ha-web/lab/terraform.tfstate`, then restore an earlier version as the current one: `aws s3api copy-object --bucket "$B" --key ha-web/lab/terraform.tfstate --copy-source "$B/ha-web/lab/terraform.tfstate?versionId=<VERSION_ID>"`. Run `terraform plan` and review before anything else. |
| State object deleted | The delete is a marker in a versioned bucket: remove it with `aws s3api delete-object --bucket "$B" --key <key> --version-id <MARKER_VERSION_ID>`. |
| Stale lock after a crashed run | The error prints the lock `ID`. Confirm in the Actions tab that no run is active, then `terraform force-unlock <ID>`. (Alternatively delete the `<key>.tflock` object.) Rehearsed locally: a foreign lock blocks a competing run with "Error acquiring the state lock", `-lock=false` plans are unaffected, and `force-unlock` clears it. |
| Apply fails with "Saved plan is stale" | State changed between plan and apply. Re-run the workflow to re-plan. |
| Bucket deleted | The bucket is outside this stack, so `terraform destroy` cannot delete it. Versions are lost with the bucket. Consider cross-region replication or periodic `terraform state pull` copies if the state matters. |

State contains sensitive values. Restrict the bucket to the two CI roles and administrators, keep Block Public Access on, and never paste state into issues.

## Verified and not verified

Verified locally (moto S3 emulator, fake AWS CLI, Terraform 1.16.2): the committed `backend.tf` is accepted by `init`, `validate`, `terraform test`, TFLint and Checkov; `terraform init -migrate-state` copies state with its serial intact and `plan` then reports no changes; a plain `init` with existing local state refuses non-interactively; native lock files are created and released and a foreign lock blocks a competing run; `terraform state list` on a never-used key exits 1 with "No state file was found!" (the CI action treats exactly that as empty); the S3 requests per operation (table above); both guard scripts across every outcome (12 cases, including fail-closed). The policy and workflow rules are enforced by `scripts/check_workflows.py`.

**Not verified (needs real AWS):** that a real bucket behaves like the emulator, in particular S3's conditional-write locking; that the IAM policies above are sufficient and no broader than needed; the real `ReadOnlyAccess` coverage of the guard's reads; the first CI run against a real bucket.
