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
| 14 | README Mermaid block parsed with Mermaid 12.2.0 | local | Superseded: the Mermaid diagram was later replaced by `docs/architecture.svg` (section 3d) |
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

## 3a. Workflow review: skipped jobs, redesign, tests

**Evidence for the skipped jobs.** GitHub's public API for the repository (unauthenticated) showed two completed runs, both on push to `main` (`c89e31a`, `0b11d50`), both `success`. In `0b11d50`, jobs 3 and 4 succeeded and **plan and apply were skipped** (conclusion `skipped`, not `failure`). Causes: plan's `if:` admitted only `workflow_dispatch` or same-repo `pull_request`, never a push; apply `needs` plan and also required `workflow_dispatch` with an `apply` input. The API also reported `environments.total_count = 0`: no `lab` Environment, hence no required reviewers, existed. These are observations of GitHub's records, not results of this review's own runs.

**Redesign** (`terraform.yml`; `terraform-destroy.yml` only changed its role variable): jobs 1-7 as separate jobs. Pull requests to `main` run static checks only; push to `main` runs checks, plan, and apply of the saved plan if it has changes (Environment `lab`); manual runs plan only. Plan artifact is AES-256 encrypted, its digest travels as a job output, and apply refuses a missing, tampered, undecryptable, wrong-commit or wrong-run plan. No `always()` outside the summary job. No `-auto-approve` anywhere in `terraform.yml`. Full description and the PR-planning decision: `docs/GITHUB_ACTIONS.md`.

**Tests run locally for this change:**

| Check | Result |
|---|---|
| `scripts/check_workflows.py` (policy assertions + simulation of `needs`/`if` over 17 named scenarios and 2,880 event/branch/outcome combinations) | OK. Invariants: apply never runs on `pull_request`; apply runs only for a push to `main` with a successful plan that has changes; no plan after a failed check; no apply after a failed plan |
| Mutation tests of that script (apply allowed on PRs; plan allowed on PRs; unpinned action; `-auto-approve`; Environment removed; plan no longer needing Checkov; `always()` on plan) | all 7 rejected; unmodified control accepted |
| Encrypt / digest / decrypt / metadata logic from jobs 5 and 6, run locally with OpenSSL 3.5.6 and a stand-in plan file | correct inputs accepted; wrong key, wrong commit, wrong run id, tampered artifact and empty expected digest all rejected; plaintext not visible in the encrypted file |
| `actionlint` (shellcheck active) on both workflows; `shellcheck` on the composite action's steps | exit 0 |
| `terraform fmt`, `init -lockfile=readonly`, `validate`, `terraform test` (12 of 12), TFLint, Checkov (235 passed, 0 failed, 32 skipped), link check | pass |

The simulator evaluates only the expression subset used in the workflows (it rejects anything else), so it checks this repository's conditions, not GitHub's evaluator in general. **The redesigned workflow has not run on GitHub**, and no AWS authentication has been tested: the OIDC provider, roles, trust policies, secrets, variables and the `lab` Environment are not configured (Environment reviewers: not verified beyond the zero-count observation above).

## 3c. Remote state (S3 backend, native locking)

**Findings.** No state or plan file exists in the repository directory and the backend was never initialised locally; every GitHub Actions run so far skipped the apply job and uploaded no artifact, so CI cannot have created anything. AWS could not be queried (credentials invalid), so a manual apply elsewhere cannot be ruled out. The old design kept the backend block in a git-ignored file that each workflow step copied (three copies, hard-coded key and region) and allowed a plan from "EMPTY state".

**Changes.** `backend.tf` is now committed as a partial S3 configuration (`encrypt`, `use_lockfile`; no DynamoDB) and bucket, key and region are passed at `init`. All AWS-backed jobs initialise through one action, `.github/actions/terraform-backend`, which requires `TF_STATE_BUCKET`, checks the bucket (reachable, versioned, public access blocked, encrypted), checks the workspace, and, if the state is empty, refuses to continue when this stack's infrastructure already exists (fails closed if it cannot tell). The plan role's state access is read-only. Procedures: `docs/REMOTE_STATE.md`.

**Tested locally against moto 5.2.4 (a local S3 emulator; not real S3) and a fake AWS CLI:**

| Test | Result |
|---|---|
| committed `backend.tf` with `init -backend=false`, `validate`, `terraform test` (12), TFLint, Checkov (235 passed, 0 failed) | pass |
| `terraform init -migrate-state` of a hand-built local state (serial 7) into the S3 backend | state copied, object versioned, `plan` reports "No changes", local file emptied and `.backup` kept |
| plain `terraform init` with existing local state, non-interactive | refuses ("Can't ask approval for state migration"); does not create an empty remote state |
| native lock: foreign `.tflock` object | competing run fails with "Error acquiring the state lock" (HTTP 412); `-lock=false` plan unaffected; `terraform force-unlock` clears it |
| S3 requests per operation (from the emulator's request log) | `init`, `state list`, `console`, `plan -lock=false`: list + GET/HEAD of the state object only; locking plan adds PUT/GET/DELETE on `.tflock`. Basis for the IAM policies |
| `terraform state list` on a never-used key | exits 1 "No state file was found!" (found while testing; the action treats exactly this as empty, other errors fail) |
| `scripts/check_state_bucket.sh` against moto | missing bucket, no versioning, no / partial public-access block, no encryption each rejected; a fully configured bucket accepted |
| `scripts/check_state_vs_infra.sh` against moto | empty account passes; VPC/IAM role with this stack's names rejected; other prefix passes; unreachable API exits 2 (fails closed) |
| `tests/state_scripts_test.sh` (fake AWS CLI, runs in CI) | 12 passed; a mutation making "infrastructure found" non-fatal is caught |
| the composite action's real `run:` steps, extracted and executed in order against moto | first deployment passes; empty state with existing infrastructure stops; existing state recognised; unfit bucket, missing bucket, key with leading `/`, key without `.tfstate` all refused |
| `scripts/check_workflows.py` new backend rules | partial config only, no DynamoDB, `backend.tf` not git-ignored, no inline backend init in any workflow; 5 mutations all rejected |
| `actionlint` (shellcheck) and `shellcheck` on the new scripts | exit 0 (after fixing a stray `
` it found in a CI step) |

Two of my own test mistakes are worth recording: Git Bash rewrote a test argument beginning with `/` (making a leading-slash key test pass wrongly until re-run with path conversion disabled), and a fake `aws` returned a stray non-zero status; neither was a project defect.

**Not verified (needs a real bucket and credentials):** real S3 conditional-write locking, the IAM policies in `REMOTE_STATE.md` (never evaluated by AWS), that `ReadOnlyAccess` covers the guard's reads, and the first CI run against a real bucket. The bucket does not exist and no state was migrated.

## 3d. Architecture diagram, roadmap and interactive page

**What exists.** `docs/architecture.svg` and `docs/roadmap.svg` (static, used in the README), `docs/ROADMAP.md`, and `docs/roadmap/` (`index.html`, `styles.css`, `app.js`, generated `data.js`, sources `roadmap.json` and `flow.json`). None of these existed before: no SVG, HTML or roadmap file was present anywhere in the project or in the sibling folders checked, so nothing was "improved"; everything was created. `scripts/build_visuals.py` generates the SVGs, `ROADMAP.md`, `data.js` and the page's inline diagram from one source, and fails if the Terraform stops matching the drawing. README order is now: title and intro, **Engineering Roadmap & Project Journey**, **Architecture**, then layout and the rest.

**Statuses.** 12 stages: 9 verified locally, 2 documented, 1 planned, **0 verified on AWS**. They are counts, not a percentage. The symbols are simplified originals, not the official AWS Architecture Icons.

| Check | Result |
|---|---|
| Diagram facts parsed from the Terraform (AZ count, NAT mode, ASG capacities, ALB scheme, fixed 403 listener, header rule, health-check paths, the five ingress and four egress security-group ports, CloudFront behaviors and HTTPS redirect, database route table, RDS settings, IMDSv2, alarm count) | all match; `build_visuals.py --check` exits 0 |
| 12 mutations of the Terraform, assets and README (AZ count, ASG capacity, ALB made public, a security-group port, unclosed HTML tag, malformed SVG, README order, README counts, a stage marked verified on AWS, `fetch()` added, missing referenced file, hand-edited generated SVG) | all 12 caught. The first run missed a changed *egress* port (only ingress was checked); egress rules are now checked too |
| SVGs rendered to PNG (resvg) and inspected | defects found and fixed: oversized arrowheads; the NAT line crossing the VPC title; "DNS lookup" hidden behind a box; a line through the database band label; "AWS: pending" chips overflowing roadmap cards; type too small. The generator also estimates text width against box width and fails when a label may overflow |
| `html-validate` on `index.html` | 4 findings fixed (three `aria-label`s on elements that ignore them, DOCTYPE style); now exit 0 |
| `postcss` parse of `styles.css`; `node --check` of `app.js`; XML parse of both SVGs | OK (185 CSS rules) |
| WCAG contrast of the palette | all 12 text/background pairs checked meet AA; lowest 4.66:1 (dimmest SVG caption), body text 14.7:1 |
| `tests/roadmap_browser_test.mjs` in headless Chrome (file://) | **61 passed, 0 failed.** Covers: no console errors and no non-file requests; roadmap before architecture; 12 stages and the status counts; open/close, filters, expand all, ArrowDown navigation; Step from idle runs exactly one step; Step during motion completes it; speed select; Play, Pause (the packet freezes while a packet is in flight), resume; run to completion with the "no request was sent" message; every packet starts at the correct end of its connection for its direction (16 movements); main-path connections lit in the expected order; Restart; Reset leaves no residue; jump to a step; layer toggles; keyboard shortcut; reduced motion (no packet, instant steps, no decorative animation); phone viewport (no horizontal page scroll, stacked layout, tap targets of at least 28px) |
| Mutation tests of the browser suite (pause does not freeze; reset leaves residue; reduced motion ignored; two request steps swapped; roadmap not first; speed select ignored) | all caught. The first version of the pause test passed vacuously (the packet was not on screen when paused); it now requires a packet in flight and fails against the broken page |
| Whole-repo regression after these changes | `terraform fmt`, `validate`, `terraform test` (12), TFLint, Checkov (235 passed, 0 failed, 32 skipped), `actionlint`, workflow policy tests, state-script tests (12), link check, credential scan: all unchanged. No Terraform, template or lock file was modified |

**Not verified.** How GitHub renders the SVGs (assumed from standard behavior of SVG used as an image: internal `<use>` references and an embedded `<style>`; scripts are never executed there, and none are used); browsers other than Chrome (Firefox, Safari, Edge); real touch devices (a phone viewport was emulated); screen readers and other assistive technology (only automated ARIA and keyboard checks were run); animation smoothness (judged only by logic and screenshots). The diagram and page show configured defaults and a simulation, not any AWS account.

## 3e. CI job 3 failure on GitHub, and what it exposed

**Observed** (GitHub's run and job records, read through its API; the raw logs need authentication and were not read): run for commit `2ada9cc` failed in job 3 at step 6, "Provider versions" (`terraform providers`), in attempt 1 and in attempt 2, which was started about a minute later. Steps 4 and 5 (`Versions`, `terraform init -backend=false`) succeeded; `validate`, `terraform test` and TFLint were skipped. The run for the next commit, `60c0db5`, passed all nine steps of job 3.

**Root cause.** `backend.tf` had just been committed with an S3 backend, and job 3 deliberately initialises with `-backend=false`. `terraform providers` reads state, so it requires an initialised backend ("Backend initialization required"). The step only printed provider versions. Attempt 2 failed identically because re-running a run executes the workflow file of the original commit, not the current `main`.

**Reproduced and verified locally.** Replaying job 3 from the workflow file as committed in `2ada9cc` (`git show`) fails in the same order GitHub recorded (`Versions` ok, `init` ok, `Provider versions` fail, rest skipped); the current workflow passes all steps (init, version listing, validate, `terraform test`, TFLint). `terraform test` was also run with the network cut (dead proxy) and invalid credentials: 12 of 12 pass, so the mocked tests need no cloud access. The fix (commit `60c0db5`) replaces the step with `terraform version` after `init`, which prints the same provider versions. `scripts/replay_ci.py` runs the real commands of jobs 1-3 so local checks cannot drift from CI again.

**Additional issues found in GitHub's annotations of that job, and fixed.**

- *Node.js 20 deprecation warning.* `checkout`, `setup-terraform` and `setup-python` declare `node20`; GitHub forces them onto Node 24 with a warning. Upgraded to releases that declare `node24`: checkout v6.0.3, setup-terraform v4.0.1, setup-python v6.3.0 (commit SHAs resolved from the tags, runtimes read from each `action.yml`, upstream changelogs read for breaking changes: none affects this repository). `upload-artifact`, `download-artifact` and `configure-aws-credentials` still declare `node20`; they are used only by the plan and apply path, which cannot run until AWS is configured, so they were deliberately not bumped blind.
- *`ubuntu-latest` migrates to Ubuntu 26.04 from 2026-10-19.* All jobs now use `ubuntu-24.04`, as GitHub recommends for stability; the policy test rejects floating `-latest` labels (mutation-tested).

Verified locally after these changes: `actionlint` exit 0, `check_workflows.py` OK, `replay_ci.py` all steps passed. Confirmation that jobs 1-4 pass on GitHub with the new pins is recorded in the commit's run, not here.

## 3b. Final review from a fresh clone (before the second push)

The committed repository was cloned into a scratch directory and checked there, so the result does not depend on untracked files: `terraform fmt -check`, `init -lockfile=readonly`, `validate`, `terraform test` (12 of 12), TFLint (exit 0), Checkov (235 passed, 0 failed, 32 skipped), `actionlint` (exit 0) and `check_links.py` (0 broken) all pass. Line endings were measured by counting 0x0D bytes with Python: 0 in the committed blobs of every tracked file and 0 in the fresh clone's bootstrap templates, with `core.autocrlf=true` on this machine, so `.gitattributes` works. An earlier `grep -c` probe reported CRs; it was a false positive (the count equalled the line count) and was disregarded after this direct measurement.

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
