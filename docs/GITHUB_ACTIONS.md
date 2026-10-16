# GitHub Actions configuration

Credentials are **never** stored in this repo. Workflows reference them by name only; the repo's existing GitHub-stored credentials were not inspected (no `.git`/remote or prior workflows existed here), so confirm which mechanism you actually have.

## Option A (preferred): OIDC role assumption — no long-lived keys

1. **Create the OIDC provider** (once per AWS account):
   ```bash
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com
   ```
   (Skip if it exists: `aws iam list-open-id-connect-providers`.)
2. **Create a role** with this trust policy (replace `ACCOUNT_ID`, `OWNER`, `REPO`). It limits assumption to this repo; the `environment` entries cover jobs that use a GitHub Environment (apply/destroy), the `pull_request` entry covers plans on PRs, and `ref:refs/heads/main` covers manual plans from main:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
         "StringLike": {
           "token.actions.githubusercontent.com:sub": [
             "repo:OWNER/REPO:pull_request",
             "repo:OWNER/REPO:ref:refs/heads/main",
             "repo:OWNER/REPO:environment:lab"
           ]
         }
       }
     }]
   }
   ```
3. **Permissions.** No verified minimal policy exists for this stack yet, because it has never been planned or applied. Do not use `AdministratorAccess` as the long-term answer. A workable approach:
   - **Plan role** (trusted for `pull_request` and `ref:refs/heads/main`): the AWS-managed `ReadOnlyAccess` policy plus read/write on the state bucket and its `.tflock` object. Planning only reads.
   - **Apply/destroy role** (trusted only for `environment:lab`): start broad enough to create the services in this repo (EC2, VPC, ELBv2, AutoScaling, RDS, CloudFront, ACM, Route 53, IAM, CloudWatch/Logs, SNS, Secrets Manager read), run one apply in a sandbox account, then replace it with a policy generated from CloudTrail by IAM Access Analyzer. Restrict `iam:PassRole` and role/instance-profile management to the `<project>-<env>-*` names this stack creates.
   - Expect the first apply in a fresh account to need `iam:CreateServiceLinkedRole` (ELB, Auto Scaling, RDS). CloudFront create actions generally cannot be resource-scoped. Treat the exact list as unverified until a real apply has been recorded in CloudTrail.
4. **Repository variable** (Settings → Secrets and variables → Actions → *Variables*): `AWS_ROLE_ARN` = the role ARN (not secret).

## Option B (fallback): existing GitHub secrets

If you already store access keys, name them exactly: **secrets** `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. Leave `AWS_ROLE_ARN` unset and the composite action `.github/actions/aws-auth` uses them (with a warning). If your secrets have other names, edit the three `secrets.AWS_*` references in the workflows. Use a dedicated least-privilege IAM user, rotate regularly. Long-lived keys cannot be scoped to a branch or environment as OIDC can.

## Other repository variables (all optional, none secret)

| Variable | Purpose |
|---|---|
| `TF_STATE_BUCKET` | S3 bucket for remote state. **Required for apply/destroy**; if unset, CI plan starts from empty state (shows everything as "create"). |
| `TF_STATE_KEY` | State key, default `ha-web/lab/terraform.tfstate` |
| `TF_VAR_DOMAIN_NAME`, `TF_VAR_HOSTED_ZONE_NAME` | Set **both** for a custom domain (e.g. `app.example.com` / `example.com`) |

### Create the state bucket (once, outside this stack)

```bash
B=<globally-unique-name>
aws s3api create-bucket --bucket $B --region us-east-1
aws s3api put-public-access-block --bucket $B --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket $B --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket $B --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
```
The role needs `s3:ListBucket` on the bucket and `s3:GetObject/PutObject/DeleteObject` on the state key and its `.tflock` file (native locking, Terraform ≥ 1.10).

## GitHub Environment (approval gate for apply/destroy)

Settings → Environments → **New environment** `lab` → enable **Required reviewers** (add yourself/team) and restrict deployment branches to `main`. The apply/destroy jobs declare `environment: lab`, so they pause for approval. If the environment doesn't exist GitHub creates it **without** protection — create it first.

### What actually protects apply and destroy

The typed phrase and the `main`-only check in the first job are guard rails against mistakes, not security boundaries: a dispatch from another branch runs *that branch's* copy of the workflow. The controls that hold are:

1. the `lab` Environment's required reviewers and **deployment-branch restriction to `main`**;
2. the IAM role's trust policy accepting only `repo:OWNER/REPO:environment:lab` for the apply role;
3. branch protection on `main`, so workflow files cannot change without review.

Any pull request opened from a branch in this repository can obtain the *plan* role's credentials through OIDC (the `pull_request` subject), because the workflow file in the PR is the one that runs. That is why the plan role must be read-only.

## Workflow behavior

| Workflow | Jobs (as shown in the Actions UI) |
|---|---|
| Terraform CI | 1 Repository checks · 2 Terraform format · 3 Init, validate, lint & test (TFLint) · 4 Security scan (Checkov) · 5 Terraform plan · 6 Workflow summary (`if: always()`) |
| Terraform Apply (manual) | 1 Validate inputs · 2 Plan & apply (Environment-gated) |
| Terraform Destroy (manual) | 1 Validate inputs · 2 Destroy (Environment-gated) |

- Plan jobs run with `-lock=false` (a PR plan only reads state and must not block or strand a lock). `terraform init -lockfile=readonly` makes CI fail if `.terraform.lock.hcl` lacks a hash for the runner's platform.
- CI runs on PRs/pushes; **plan** runs on same-repo PRs and manual dispatch (fork PRs have no secrets/OIDC, so plan is skipped, not failed).
- Apply/destroy: `workflow_dispatch` only, from `main`, with typed phrases `APPLY us-east-1` / `DESTROY us-east-1`, remote state required. Concurrency group per environment prevents overlapping state changes and never cancels a running apply.
- Plan output is uploaded only as a text log (7 days); the binary plan is never uploaded. Terraform masks `sensitive` values, but anyone with repo read access can download artifacts — keep the repo private.
- Third-party actions are pinned to full commit SHAs with the release in a trailing comment. Each SHA was checked against the upstream tag with `git ls-remote` (all are lightweight tags, so the SHA is the commit). Update them deliberately, e.g. with Dependabot's `github-actions` ecosystem.
- Terraform pinned to `1.16.2` (the version used for local validation) and Checkov to `3.3.29`.
