# GitHub publishing checklist

Everything below is a manual step; nothing here has been done for you. `[ ]` items need your decision or an AWS/GitHub login.

## Before the first push

- [ ] `.gitattributes` forces LF line endings. Keep it: a CRLF checkout of `templates/*.tftpl` on Windows would break the bootstrap scripts.
- [ ] Review the file list: `git status --short` should show only source files (no `.terraform/`, `*.tfstate`, `*.tfvars`, `*.tfbackend`, plans). `backend.tf` itself IS tracked: it holds no values.
- [ ] `git diff --cached` (after `git add`) read through once. Confirm no account IDs, domains or e-mail addresses you consider private.
- [ ] `LICENSE` is Apache-2.0 (unmodified text from apache.org). If you want a copyright notice in source files or a `NOTICE` file, add your own name; none was invented.
- [ ] Create the repository **private first**, and make it public only after the checks below pass.

## Repository settings (GitHub UI)

- [ ] Settings → Actions → General: set workflow permissions to **read** by default; require approval for workflows from outside collaborators.
- [ ] Settings → Environments → **New environment `lab`**: add *Required reviewers*, restrict to branch `main`. **Create it before the first push that has plan changes**; if it does not exist when the apply job starts, GitHub creates an unprotected one and the apply proceeds without approval. (At review time the API reported zero Environments.)
- [ ] Settings → Branches: protect `main` (require PR, require the *Terraform CI* checks).
- [ ] Settings → Code security: enable secret scanning and push protection; enable Dependabot for `github-actions`.
- [ ] Authentication (see [`GITHUB_ACTIONS.md`](GITHUB_ACTIONS.md)): prefer OIDC with two roles (repository **variables** `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`). Trust policy subjects: plan role `...:ref:refs/heads/main`, apply role `...:environment:lab`; verify them with the read-only `aws iam get-role` commands in that file. Use `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` secrets only as a fallback. Never paste credentials into issues, logs or chat.
- [ ] **Remote state first** ([`REMOTE_STATE.md`](REMOTE_STATE.md)): check whether state or infrastructure already exists (section "Is there existing state?"), then create the bucket, then set the variable `TF_STATE_BUCKET` (**required**; optional `TF_STATE_KEY`, `TF_STATE_REGION`). If state already exists, migrate it before the first CI run.
- [ ] Optional variables: `TF_VAR_DOMAIN_NAME`, `TF_VAR_HOSTED_ZONE_NAME`.
- [ ] Secret `TF_PLAN_ENCRYPTION_KEY` (**required**; `openssl rand -base64 48`). Without it, every push to `main` fails at job 5 with an explicit message.

## Checks to run with working AWS credentials (not done yet)

```bash
aws sts get-caller-identity                                  # credentials valid?
aws ec2 describe-images --region us-east-1 --image-ids ami-0ed59cbb87dfa8dba \
  --query 'Images[0].[ImageId,Name,Architecture,PlatformDetails,State,OwnerId,RootDeviceName]' --output table
aws rds describe-orderable-db-instance-options --engine postgres --engine-version 16 \
  --db-instance-class db.t3.micro --region us-east-1 \
  --query 'OrderableDBInstanceOptions[].[EngineVersion,MultiAZCapable]' --output table
aws ec2 describe-managed-prefix-lists --region us-east-1 \
  --filters Name=prefix-list-name,Values=com.amazonaws.global.cloudfront.origin-facing \
  --query 'PrefixLists[].[PrefixListName,MaxEntries]' --output table     # AWS docs say weight 55
terraform plan                                               # read the whole plan before any apply
```

After `describe-images`, put the AMI's `OwnerId` into `ami_owner_id` in your `terraform.tfvars` so the plan fails if it ever differs.

Do not run `terraform apply` until the AMI is confirmed and you have read `COST_AND_CLEANUP.md`.

## After the first push

- [ ] Open a pull request into `main`: jobs 1-4 and 7 run; jobs 5 and 6 show **skipped** (by design); no AWS access is used.
- [ ] After merging, a push to `main` runs 1-5 and, if the plan has changes, pauses job 6 for Environment approval. Check the run summary: it lists resource addresses and actions only, never values.
- [ ] Confirm no credentials appear in any log, and that the only artifact is `tfplan-<sha>-<run>` (an encrypted `.enc` file).
- [ ] Confirm a manual run from *Actions → Terraform CI → Run workflow* plans but never applies.
- [ ] Only then add a README status line about what was actually deployed, with evidence.
