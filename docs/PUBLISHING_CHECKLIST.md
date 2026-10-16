# GitHub publishing checklist

Everything below is a manual step; nothing here has been done for you. `[ ]` items need your decision or an AWS/GitHub login.

## Before the first push

- [ ] `.gitattributes` forces LF line endings. Keep it: a CRLF checkout of `templates/*.tftpl` on Windows would break the bootstrap scripts.
- [ ] Review the file list: `git status --short` should show only source files (no `.terraform/`, `*.tfstate`, `*.tfvars`, `backend.tf`, plans).
- [ ] `git diff --cached` (after `git add`) read through once. Confirm no account IDs, domains or e-mail addresses you consider private.
- [ ] `LICENSE` is Apache-2.0 (unmodified text from apache.org). If you want a copyright notice in source files or a `NOTICE` file, add your own name; none was invented.
- [ ] Create the repository **private first**, and make it public only after the checks below pass.

## Repository settings (GitHub UI)

- [ ] Settings → Actions → General: set workflow permissions to **read** by default; require approval for workflows from outside collaborators.
- [ ] Settings → Environments → **New environment `lab`**: add *Required reviewers*, restrict to branch `main`. Create it before the first apply/destroy run, otherwise GitHub creates an unprotected one.
- [ ] Settings → Branches: protect `main` (require PR, require the *Terraform CI* checks).
- [ ] Settings → Code security: enable secret scanning and push protection; enable Dependabot for `github-actions`.
- [ ] Authentication (see [`GITHUB_ACTIONS.md`](GITHUB_ACTIONS.md)): prefer OIDC (`AWS_ROLE_ARN` repository **variable**). Use `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` secrets only as a fallback. Never paste credentials into issues, logs or chat.
- [ ] Optional variables: `TF_STATE_BUCKET`, `TF_STATE_KEY`, `TF_VAR_DOMAIN_NAME`, `TF_VAR_HOSTED_ZONE_NAME`.

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

- [ ] Open a PR; confirm jobs 3 (init/validate/lint/test), 4 (Checkov) and 5 (plan) appear and job 6 (apply) is skipped.
- [ ] Confirm the plan job authenticates (OIDC) without printing credentials, and that the uploaded artifact is the text log only.
- [ ] Confirm job 6 (apply) runs only from *Actions → Terraform CI → Run workflow* with *apply* ticked, and pauses for Environment approval. `terraform apply -auto-approve` has no further prompt after that approval.
- [ ] Only then add the README status line about what was actually deployed, with evidence.
