# Validation report

A record of checks that were actually executed, their results, and what remains unverified. **No AWS infrastructure was planned, applied or inspected.** Nothing here is evidence of a deployment.

Tooling: Terraform 1.16.2 (windows_amd64); AWS provider 6.69.1 and random 3.9.1 (locked); AWS CLI 2.35.20; Checkov 3.3.29; TFLint 0.64.0 with the AWS ruleset 0.49.0; Trivy 0.76.0; shellcheck (via `shellcheck-py`); actionlint 1.7.12; Mermaid 12.2.0 (parser); Python 3.13; Node (for the Mermaid parse); Git Bash for `bash -n`. TFLint and Trivy release archives were verified against the SHA-256 checksums published with each release.

## 1. AWS access: failed

| Command | Result |
|---|---|
| `aws sts get-caller-identity` | `InvalidClientTokenId: The security token included in the request is invalid.` (latest attempt: end of the final audit) |
| `aws ec2 describe-images --region us-east-1 --image-ids ami-0ed59cbb87dfa8dba` | `AuthFailure: AWS was not able to validate the provided access credentials` |

Consequences: the AMI `ami-0ed59cbb87dfa8dba` is **unverified**; `terraform plan`, `apply` and `destroy` were never run; no AWS resource exists because of this project.

## 2. Checks on the final tree

Local = runs on this machine without AWS. Mocked = Terraform's `mock_provider`; proves logic and guard rails, not that AWS accepts the resources.

| # | Check | Kind | Result |
|---|---|---|---|
| 1 | `terraform fmt -check -recursive` | local | exit 0 |
| 2 | `terraform init -backend=false -lockfile=readonly` | local | success (lock file already complete) |
| 3 | `terraform validate` | local | success |
| 4 | `terraform test` | mocked | 12 passed, 0 failed |
| 5 | `tflint --recursive` (terraform + AWS rulesets) | local | exit 0, no findings |
| 6 | `checkov -d . --framework terraform` | local | 235 passed, 0 failed, 32 skipped (each skip inline with a reason) |
| 7 | `trivy config .` (HIGH/CRITICAL) | local | 4 distinct findings, all accepted design decisions, see section 4 |
| 8 | `actionlint` on 3 workflows, with shellcheck active for `run:` blocks | local | exit 0 |
| 9 | `shellcheck` on both rendered `user_data` scripts and on the composite action's `run:` steps | local | exit 0 |
| 10 | YAML parse of the workflows and composite action | local | 4 files OK |
| 11 | `scripts/check_links.py` (relative Markdown links) | local | 7 files, 0 broken. Negative test with a deliberate broken link: reported it, exit 1 |
| 12 | Both `user_data` templates rendered, `bash -n` | local | OK; no unrendered `${`/`%{` |
| 13 | Backend Python app extracted from the rendered script, `py_compile` | local | OK |
| 14 | README Mermaid block parsed with Mermaid 12.2.0 | local | 1 block, valid `flowchart-v2`. Negative control: a broken diagram was rejected. Syntax only; visual layout was not rendered |
| 15 | `.gitignore` / `.gitattributes` in a throwaway repo | local | 12 of 12 sensitive paths ignored; only `.gitattributes`, `.gitignore`, `.terraform.lock.hcl`, `.tflint.hcl`, `LICENSE`, `*.example` are committable; `*.tftpl` resolves to `eol=lf` |
| 16 | Provider lock file | local | `providers lock` for 5 platforms re-run: file byte-identical; 5 `h1:` hashes per provider (linux amd64/arm64, darwin amd64/arm64, windows amd64) |
| 17 | Staging simulation (project copied to a scratch dir, `git init`, `git add -A`) | local | 49 files staged; `.terraform/` ignored; CI's forbidden-files, required-files and credential-pattern rules all pass; no local paths, user names or e-mail addresses; no CRLF in staged blobs; lock file tracked |
| 18 | Line-ending fix, rendered through `jsonencode` | local | CRLF template: 91 carriage returns reach `user_data` without the fix, 0 with it |

Not applicable because the files do not exist in this repository: SVG/XML parsing, HTML/CSS/JavaScript checks, and any review of `docs/architecture.svg`, `docs/roadmap.svg` or an interactive roadmap. The README's Mermaid block is the only diagram. Nothing was invented to fill the gap.

`terraform test` covers: HA defaults; domain/ACM/alias gating; single-NAT mode; AMI owner accepted/rejected; engine and parameter-group family consistent/mismatched; storage ceiling below initial storage; AMI/instance-type architecture mismatch; domain without zone; `min = 1`; non-`us-east-1` region.

## 3. Defects found and fixed (cumulative)

Earlier rounds: ineffective Checkov skips; ACM validation `for_each` on an apply-time value; no CloudFront default root object; no RDS enhanced monitoring; stale `-target` address after the module refactor; four no-op DNS security-group rules; ASGs not waiting for the listener/rule that attaches their target group; RDS log groups without retention; corrupted README encoding; `project_name`/`environment` accepting double or trailing hyphens; Windows-only lock file; unpinned actions.

This round:

- **CI would have failed on first run.** The repository's own credential-pattern rule matched the literal text in `VALIDATION_REPORT.md` that described the scan. Found by running CI's rules against a simulated staged tree; reworded and re-verified.
- **Windows checkout would have broken every instance.** With Git's `core.autocrlf=true`, `*.tftpl` files check out as CRLF and `templatefile()` would pass `\r` into the bash `user_data`. Added `.gitattributes` (`eol=lf`) and `replace(..., "\r", "")` around both `templatefile()` calls; effect measured in check 18.
- **PR plans took the state lock.** Plan jobs now use `-lock=false` (read-only, and a cancelled run can no longer strand a lock). Apply and destroy still lock.
- **Lock file not enforced in CI.** `terraform init -lockfile=readonly` now fails CI if a platform hash is missing.
- **Late apply-time failures made plan-time.** Added preconditions: `db_parameter_group_family` must match `db_engine_version`'s major version; `db_max_allocated_storage` must be 0 or ≥ `db_allocated_storage`; `db_allocated_storage` ≥ 20 (gp3 minimum). Each has a test.
- **AMI ownership.** New optional `ami_owner_id`; when set, plan fails if the AMI has a different owner (Trivy AWS-0344). It defaults to unset because the real owner is unknown without credentials.
- **New CI steps:** Markdown link check; TFLint (`terraform-linters/setup-tflint` pinned to the verified `v6.3.2` commit).
- Docs now state that the typed phrase and `main`-only check are guard rails, and that the Environment's branch restriction, the role trust policy and branch protection are what actually protect apply/destroy. They also state that any in-repo PR can obtain the *plan* role through OIDC, so that role must be read-only.

## 4. Scanner findings that are accepted, not fixed

| Finding | Why it stays |
|---|---|
| Trivy AWS-0053 / Checkov: external ALB is public | It is the CloudFront origin. Reachable only from the CloudFront prefix list **and** only with the secret header (default action is 403). |
| Trivy AWS-0054 / Checkov CKV_AWS_2, 103, 378, CKV2_AWS_20: HTTP listeners | CloudFront → ALB and ALB → instance run over HTTP. Documented as a limitation; the viewer leg is HTTPS. |
| Trivy AWS-0011/0010, Checkov CKV_AWS_68/86, CKV2_AWS_28/47: no WAF, no access logs | Cost and scope; documented. |
| Trivy AWS-0104: egress to `0.0.0.0/0` (4 rules) | TCP 80 and 443 only, from the app tiers, for package installs and Session Manager via NAT. Interface endpoints would remove the need at an hourly cost per endpoint per AZ. |
| Trivy AWS-0017, Checkov CKV_AWS_158/338/26: log-group and SNS KMS, 1-year retention | CMK complexity and cost; retention is a variable. |
| Trivy AWS-0133, Checkov CKV_AWS_353: Performance Insights | Unsupported on `db.t3.micro`. |

## 5. Requires working AWS credentials (not verified)

| Item | How to check |
|---|---|
| AMI exists, is `available`, `Linux/UNIX`, matches the instance type's architecture; its owner (then set `ami_owner_id`) | `describe-images` (README); `terraform plan` enforces the rest |
| `db.t3.micro` orderable for PostgreSQL 16 with Multi-AZ in `us-east-1` | `describe-orderable-db-instance-options` (command in `PUBLISHING_CHECKLIST.md`) |
| Prefix list `MaxEntries` in this account/region (AWS docs state weight 55 against a default quota of 60) | `describe-managed-prefix-lists` |
| Provider accepts every argument; the first plan is clean | `terraform plan` |
| Bootstrap on the AMI: package installs, `systemd`, nginx and Python start, health checks go green | first deployment; `TROUBLESHOOTING.md` §3-4. Local syntax and shellcheck do not prove the services start |
| nginx resolves the internal ALB (relies on resolver traffic not being security-group filtered) | first deployment |
| Required IAM permissions for the CI roles | not determined; see `GITHUB_ACTIONS.md` |
| GitHub: workflows run, OIDC trust works, Environment gate pauses apply/destroy | first PR / first manual run |

## 6. Not done

- No GitHub secrets, variables or Environments were inspected; no repository or remote exists here, and the project directory is not a Git repository (staging was simulated in a scratch copy).
- Trivy is not part of CI (its accepted findings would be noise next to Checkov); run it locally with `trivy config .`.
- Actions are pinned to full commit SHAs; their upstream tags were checked with `git ls-remote`. The actions' code itself was not audited.
- Cost figures in `COST_AND_CLEANUP.md` are estimates, not queried prices.
- Terraform state will contain the CloudFront-to-ALB shared header value; the database password is not in state.
