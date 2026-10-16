#!/usr/bin/env python3
"""Replay the `run:` steps of CI jobs locally, exactly as written in the workflow file.

Why: checks that approximate CI drift from it. This runs the real commands of the real jobs, in order,
with `bash -eo pipefail` like a GitHub runner, so a step that would fail in CI fails here first.
`uses:` steps (actions that only install tools) are skipped: install Terraform, TFLint, Python and PyYAML yourself.
Only jobs that need no AWS access make sense here (repository-checks, terraform-format, terraform-init-validate).

Usage: python scripts/replay_ci.py [job-id ...]      default: repository-checks terraform-format terraform-init-validate
Needs: PyYAML, bash (on Windows, Git Bash is used), and the tools those jobs call.
"""
import os
import pathlib
import shutil
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_JOBS = ["repository-checks", "terraform-format", "terraform-init-validate"]


def find_bash() -> str:
    if os.name == "nt":  # `bash` on Windows may be the WSL stub, which fails when no distribution is installed
        for candidate in (r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files (x86)\Git\bin\bash.exe"):
            if os.path.exists(candidate):
                return candidate
    return shutil.which("bash") or "bash"


def main() -> int:
    jobs = sys.argv[1:] or DEFAULT_JOBS
    wf = yaml.safe_load((ROOT / ".github" / "workflows" / "terraform.yml").read_text(encoding="utf-8"))
    base = dict(os.environ, **{k: str(v) for k, v in (wf.get("env") or {}).items()}, GITHUB_TOKEN="", GITHUB_SHA="local")
    bash = find_bash()
    failed = False
    for job_id in jobs:
        job = wf["jobs"][job_id]
        print(f"=== {job['name']}")
        for step in job["steps"]:
            if "run" not in step:
                continue
            env = dict(base)
            for k, v in (step.get("env") or {}).items():
                env[k] = "" if "${{" in str(v) else str(v)  # secrets and vars are not available locally
            r = subprocess.run([bash, "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]], cwd=ROOT, env=env,
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
            print(f"  [{'ok  ' if r.returncode == 0 else 'FAIL'}] {step.get('name', '(unnamed)')}")
            if r.returncode != 0:
                failed = True
                for line in (r.stdout + r.stderr).strip().splitlines()[-8:]:
                    print("        " + line[:200])
                break
    print("replay: FAILED" if failed else "replay: all steps passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
