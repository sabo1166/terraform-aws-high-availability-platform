# GitHub Actions configuration

Credentials are never stored in this repository. Workflows read them by name from GitHub secrets and variables.

**Status:** the workflow structure is tested locally (`scripts/check_workflows.py`, `actionlint`). The AWS side (OIDC provider, roles, trust policies, Environment, secrets) is **not configured or tested**; every AWS authentication path below is unverified until a run succeeds.

## Behavior

| Event | 1 Repo checks | 2 Format | 3 Validate/lint/test | 4 Checkov | 5 Plan | 6 Apply | 7 Summary |
|---|---|---|---|---|---|---|---|
| Pull request to `main` (same repo or fork) | run | run | run | run | **skipped (by design)** | **skipped (by design)** | run |
| Push to `main` | run | run | run | run | run | run if the plan has changes, after approval | run |
| Manual run on `main` | run | run | run | run | run | skipped (never applies) | run |
| Manual run on another branch | run | run | run | run | skipped | skipped | run |
| Any required check fails | stops here | | | | skipped | skipped | reports the first failure |

`terraform-destroy.yml` is a separate, manual-only workflow gated by the same Environment. Nothing destroys automatically.

**Decision: pull requests run static checks only, not an AWS-backed plan.** With OIDC, the workflow file *in the pull request* is the one that runs, so a PR-triggered plan would let any branch in this repository obtain AWS credentials (a trust policy for `repo:OWNER/REPO:pull_request` cannot distinguish a reviewed change from a malicious one). In a public repository, plan output would also expose resource names and the account ID. The cost is that plan errors surface only after merge; reviewers rely on the static checks, the mocked `terraform test` suite and Checkov. If you later want PR plans, add a separate read-only role trusted for `pull_request`, keep the repository private, and extend `scripts/check_workflows.py` to match.

### Why jobs were skipped (evidence from the first runs)

GitHub's API for the public repository showed two successful runs on push to `main`: jobs 3 and 4 succeeded, **plan and apply were skipped, not failed**.

- *Plan* had `if: workflow_dispatch || same-repo pull_request`. A push matches neither, so it was skipped.
- *Apply* was skipped twice over: it `needs` plan (a skipped need skips its dependents) and its own `if` required a manual dispatch with an `apply` input.
- At that time the repository had **no GitHub Environments** (`total_count: 0`), so no required reviewers existed.

The current workflow deliberately never uses `always()` outside the summary job, so a failed or skipped prerequisite keeps plan and apply from running. Job 7 names the first failing job and explains each skip. `scripts/check_workflows.py` simulates GitHub's `needs`/`if` semantics over 2,880 event, branch and failure combinations.

## Plan and apply integrity

1. Job 5 plans with `-detailed-exitcode -out=tfplan` (exit 0 = no changes, 2 = changes, 1 = error). With no changes, nothing is uploaded and apply is skipped.
2. The plan file can contain secret state values (for example the CloudFront origin-verify header), and artifacts of a public repository are downloadable by any GitHub user. So the plan is packed with run metadata, **encrypted with AES-256 (OpenSSL, PBKDF2)** using the secret `TF_PLAN_ENCRYPTION_KEY`, and only then uploaded, and only after a successful plan. The unencrypted plan and `plan.log` are never uploaded.
3. The SHA-256 of the encrypted file is a job output (a different channel from the artifact store). Job 6 refuses the artifact if the digest differs, if it is missing, if decryption fails, or if the metadata names a different commit or run. Each failure ends with "Nothing was applied."
4. Job 6 applies `tfplan` itself (`terraform apply tfplan`), not a fresh plan. Terraform rejects a saved plan whose state is stale, so a change between plan and approval fails instead of applying something unreviewed. Re-run the workflow to re-plan.
5. Both jobs initialise state through the same action (`.github/actions/terraform-backend`): the same bucket, key and region, `-lockfile=readonly`, the repository root as working directory, and the same `TF_VAR_*` repository variables (the plan embeds its variable values). The action checks the bucket, the `default` workspace, and refuses to continue when the state is empty but this stack's infrastructure already exists. There is no local or empty-state path. Details: [`REMOTE_STATE.md`](REMOTE_STATE.md).
6. Logs and the run summary show only resource **addresses and actions**, never attribute values. Terraform masks `sensitive` values in its own output.
7. Plan artifacts expire after 5 days; the artifact name includes the commit SHA and run ID.
8. Concurrency: runs for `main` are never cancelled (one may be applying); the apply job also holds the group `terraform-state-lab`.

## Authentication

### Preferred: GitHub OIDC with two roles

Short-lived credentials, no stored keys. Use **two roles** so the job that runs on every push to `main` has no write access.

1. **OIDC provider** (once per account):
   ```bash
   aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com
   ```
2. **Plan role** (`AWS_PLAN_ROLE_ARN`). Job 5 has no Environment, so its token subject is the branch ref. Trust policy (replace `ACCOUNT_ID`, `OWNER`, `REPO`):
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com" },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
           "token.actions.githubusercontent.com:sub": "repo:OWNER/REPO:ref:refs/heads/main"
         }
       }
     }]
   }
   ```
   There is intentionally no `pull_request` subject. Permissions: the AWS-managed `ReadOnlyAccess` policy plus **read-only** access to the state object (`s3:ListBucket` on the bucket, `s3:GetObject` on the state key). CI plans with `-lock=false`, which touches no lock object, so this role needs no S3 write access. The exact statements, derived from the S3 requests Terraform makes, are in [`REMOTE_STATE.md`](REMOTE_STATE.md#iam-permissions-for-state).
3. **Apply role** (`AWS_APPLY_ROLE_ARN`, also used by `terraform-destroy.yml`). Job 6 declares `environment: lab`, so its subject becomes the Environment. Same trust policy with `"token.actions.githubusercontent.com:sub": "repo:OWNER/REPO:environment:lab"`. Permissions: see below.
4. **Repository variables** (not secret): `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`. A single `AWS_ROLE_ARN` is accepted as a fallback for both, which is not recommended.

**Apply-role permissions.** No verified minimal policy exists, because the stack has never been planned or applied. Do not make `AdministratorAccess` permanent. Start broad enough for EC2, VPC, ELBv2, Auto Scaling, RDS, CloudFront, ACM, Route 53, IAM (restricted to `<project>-<env>-*` role and instance-profile names, with `iam:PassRole` limited to those), CloudWatch/Logs, SNS, Secrets Manager (read), and the state bucket; apply once in a sandbox account; then replace it with a policy generated from CloudTrail by IAM Access Analyzer. Expect `iam:CreateServiceLinkedRole` on first use of ELB, Auto Scaling and RDS in an account. CloudFront create actions generally cannot be resource-scoped.

**Verify the AWS side instead of assuming it** (read-only; run with working credentials):

```bash
aws iam list-open-id-connect-providers
aws iam get-open-id-connect-provider --open-id-connect-provider-arn <ARN> --query '{Url:Url,ClientIDList:ClientIDList}'
aws iam get-role --role-name <PLAN_ROLE> --query 'Role.AssumeRolePolicyDocument'     # sub must be ...:ref:refs/heads/main
aws iam get-role --role-name <APPLY_ROLE> --query 'Role.AssumeRolePolicyDocument'    # sub must be ...:environment:lab
aws iam list-attached-role-policies --role-name <PLAN_ROLE>
```

Checks to read off those outputs: the provider URL is `https://token.actions.githubusercontent.com`; `ClientIDList` contains `sts.amazonaws.com` (the audience `aws-actions/configure-aws-credentials` requests); each trust policy names exactly the subject above for the right role; the plan role has no write permissions. A correctly formatted role ARN does **not** prove the role exists or trusts this repository. The composite action `.github/actions/aws-auth` only validates the ARN's format; only a real run (`sts:AssumeRoleWithWebIdentity`) shows that authentication works, and none has run.

### Fallback: long-lived access keys

Leave the `*_ROLE_ARN` variables unset and the action uses secrets named exactly `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (with a warning in the log). To limit the damage, store **read-only** keys as repository secrets (used by job 5) and the **apply-capable** keys as secrets of the `lab` Environment. Environment secrets with the same names override repository secrets for jobs that use that Environment. Otherwise anyone who can push to `main` can run a modified workflow that exposes the apply keys. Rotate regularly.

## Repository variables and secrets

| Name | Kind | Required for | Purpose |
|---|---|---|---|
| `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN` | variable | OIDC | roles above (or `AWS_ROLE_ARN` for both) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | secret | key fallback | see above |
| `TF_STATE_BUCKET` | variable | **every AWS-backed run** | S3 state bucket ([`REMOTE_STATE.md`](REMOTE_STATE.md)). Without it the run fails immediately with a clear error. |
| `TF_STATE_KEY` | variable | optional | default `ha-web/lab/terraform.tfstate` |
| `TF_STATE_REGION` | variable | optional | region **of the bucket**, default `us-east-1` |
| `TF_PLAN_ENCRYPTION_KEY` | **secret** | push plan, apply | encrypts the plan artifact. Generate with `openssl rand -base64 48`; keep a copy: rotating it between plan and apply makes that run's apply fail (re-run). |
| `TF_VAR_DOMAIN_NAME`, `TF_VAR_HOSTED_ZONE_NAME` | variable | optional | set **both** or neither |

### State bucket

Create it once, outside this stack, as described in [`REMOTE_STATE.md`](REMOTE_STATE.md#create-the-bucket-once-outside-this-stack): private, versioned, encrypted, with a policy that denies non-TLS access. The apply role additionally needs write access to the state object and read/write/delete on its `.tflock` object; those statements are in the same document.

## GitHub Environment `lab` (the approval gate)

Settings → Environments → **New environment** `lab`, then:

- **Required reviewers**: add yourself or a team. Consider enabling "Prevent self-review" if more than one person can approve.
- **Deployment branches and tags**: *Selected branches* → `main` only.
- Put the apply-capable key secrets here if you use the key fallback.

Create it **before** the first push that produces a plan with changes. If the Environment does not exist when job 6 starts, GitHub creates it with no protection and the apply would proceed without approval. Check the configuration at any time:

```bash
gh api repos/OWNER/REPO/environments/lab --jq '{reviewers: [.protection_rules[] | select(.type=="required_reviewers")], branches: .deployment_branch_policy}'
```

At the time of the review that call returned `total_count: 0` for this repository: the Environment did not exist.

Also enable branch protection on `main` (require pull requests and the "Terraform CI" checks). The workflow file is part of what runs on a push, so anyone who can push to `main` can change the pipeline; branch protection and the Environment's reviewers are the real controls, not anything inside the workflow.

## Reading a failed or skipped run

Job 7 ("Workflow summary") always runs, lists every job with its result and a note for each skip, and fails with "First failing prerequisite: …". **Skipped is not failed**: plan is skipped on pull requests by design, and apply is skipped when the plan has no changes. Start at the first failed job in the table.

## Pinned versions

Third-party actions are pinned to full commit SHAs with the release in a trailing comment (checked against the upstream tags with `git ls-remote`; `scripts/check_workflows.py` fails on any unpinned reference). Terraform is pinned to `1.16.2`, Checkov to `3.3.29`, TFLint to `v0.64.0`, PyYAML to `6.0.2`. Update deliberately (Dependabot's `github-actions` ecosystem works for the action SHAs).

## Public repositories

Job logs and artifacts of a public repository are readable by everyone. Plan output (addresses, and error text) can include resource names and your AWS account ID. The plan artifact is encrypted, and logs show only addresses and actions, but a private repository is still the safer home for a pipeline that deploys real infrastructure.
