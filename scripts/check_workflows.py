#!/usr/bin/env python3
"""Policy and event/dependency tests for the GitHub Actions workflows.

1. Static policy: triggers, pinned actions, permissions, no auto destroy, no pull-request apply, the
   Environment gate, no always() outside the summary job.
2. Simulation: evaluates each job's `if:` and `needs:` the way GitHub does (a job runs only if every
   need succeeded and its `if` is true; a skipped or failed need skips its dependents) for many
   event / branch / prerequisite-failure combinations, and asserts the intended behavior.

The expression evaluator supports only the subset used in these workflows (==, !=, &&, ||, !,
parentheses, string literals, context lookups). Anything else raises, so a new construct forces this
test to be extended deliberately.

Usage: python scripts/check_workflows.py [repo_root]     (needs PyYAML)
"""
import itertools
import pathlib
import re
import sys

import yaml

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
WF_DIR = ROOT / ".github" / "workflows"
failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        failures.append(msg)


def load(name: str) -> dict:
    return yaml.safe_load((WF_DIR / name).read_text(encoding="utf-8"))


def triggers(wf: dict) -> dict:
    # PyYAML parses the bare key `on` as boolean True.
    on = wf.get("on", wf.get(True))
    return on if isinstance(on, dict) else {k: None for k in ([on] if isinstance(on, str) else on)}


def step_text(job: dict) -> str:
    return "\n".join(str(s.get("run", "")) for s in job.get("steps", []))


# --------------------------------------------------------------------------- expression evaluator
TOKEN = re.compile(r"\s+|'[^']*'|&&|\|\||!=|==|[()!]|[A-Za-z_][A-Za-z0-9_.\-]*")


def evaluate(expr, ctx: dict) -> bool:
    if expr is None or expr == "":
        return True
    if isinstance(expr, bool):
        return expr
    text = re.sub(r"^\s*\$\{\{|\}\}\s*$", "", str(expr)).strip()
    out, pos = [], 0
    for m in TOKEN.finditer(text):
        if m.start() != pos:
            raise ValueError(f"unsupported expression syntax near {text[pos:pos + 25]!r}: {text!r}")
        tok, pos = m.group(0), m.end()
        if tok.isspace():
            continue
        if tok == "&&":
            out.append(" and ")
        elif tok == "||":
            out.append(" or ")
        elif tok == "!":
            out.append(" not ")
        elif tok in ("==", "!=", "(", ")") or tok.startswith("'"):
            out.append(tok)
        elif tok in ("true", "false", "null"):
            out.append({"true": "True", "false": "False", "null": "None"}[tok])
        elif re.match(r"^[A-Za-z_]", tok) and tok not in ("and", "or", "not"):
            if tok.endswith("()") or tok in ("always", "success", "failure", "cancelled", "contains", "format"):
                raise ValueError(f"function {tok!r} is not supported by this test: {text!r}")
            out.append(f"ctx.get({tok!r})")
        else:
            raise ValueError(f"unsupported token {tok!r} in {text!r}")
    if pos != len(text):
        raise ValueError(f"unsupported expression syntax near {text[pos:pos + 25]!r}: {text!r}")
    return bool(eval("".join(out), {"__builtins__": {}}, {"ctx": ctx}))  # noqa: S307 (own workflow text)


# ----------------------------------------------------------------------------------- simulation
ORDER = [
    "repository-checks",
    "terraform-format",
    "terraform-init-validate",
    "terraform-security-scan",
    "terraform-plan",
    "terraform-apply",
]
CHECKS = ORDER[:4]


def simulate(jobs: dict, ctx: dict, forced: dict) -> dict:
    """Return {job: success|failure|skipped}. `forced` sets the outcome of jobs that would run."""
    status: dict = {}
    for name in ORDER:
        job = jobs[name]
        needs = job.get("needs", [])
        needs = [needs] if isinstance(needs, str) else needs
        if any(status[n] != "success" for n in needs):
            status[name] = "skipped"  # no always(): a failed or skipped need skips this job
            continue
        local = dict(ctx)
        if status.get("terraform-plan") == "success":
            local["needs.terraform-plan.outputs.has_changes"] = ctx.get("plan_has_changes", "")
        try:
            runs = evaluate(job.get("if"), local)
        except ValueError as exc:  # an unsupported construct must fail the test, not crash it
            check(False, f"{name}: {exc}")
            runs = False
        if not runs:
            status[name] = "skipped"
            continue
        status[name] = forced.get(name, "success")
    return status


def context(event: str, ref_name: str, default: str = "main", fork: bool = False, has_changes: str = "true") -> dict:
    return {
        "github.event_name": event,
        "github.ref_name": ref_name,
        "github.ref": f"refs/heads/{ref_name}",
        "github.event.repository.default_branch": default,
        "github.repository": "owner/repo",
        "github.event.pull_request.head.repo.full_name": "other/repo" if fork else "owner/repo",
        "plan_has_changes": has_changes,
    }


def main() -> int:
    tf = load("terraform.yml")
    destroy = load("terraform-destroy.yml")
    jobs = tf["jobs"]

    # ---------------------------------------------------------------- static policy
    on = triggers(tf)
    check(set(on) == {"pull_request", "push", "workflow_dispatch"}, f"terraform.yml triggers are {sorted(on)}")
    check((on.get("pull_request") or {}).get("branches") == ["main"], "pull_request must target main only")
    check((on.get("push") or {}).get("branches") == ["main"], "push must be limited to main")
    for f in sorted(WF_DIR.glob("*.yml")):
        t = triggers(yaml.safe_load(f.read_text(encoding="utf-8")))
        check(not {"pull_request_target", "schedule", "workflow_run", "issue_comment"} & set(t), f"{f.name}: forbidden trigger {sorted(t)}")
    check(set(triggers(destroy)) == {"workflow_dispatch"}, "terraform-destroy.yml must be workflow_dispatch only")
    check("environment" in destroy["jobs"]["destroy"], "destroy job must use a GitHub Environment")

    for name, job in jobs.items():
        run = step_text(job)
        check("terraform destroy" not in run and "-destroy" not in run, f"{name}: must not destroy")
        check("-auto-approve" not in run, f"{name}: must not use -auto-approve (apply consumes a saved plan)")

    for f in sorted(WF_DIR.glob("*.yml")) + [ROOT / ".github" / "actions" / "aws-auth" / "action.yml"]:
        for m in re.finditer(r"uses:\s*(\S+)", f.read_text(encoding="utf-8")):
            ref = m.group(1)
            if not ref.startswith("./"):
                check(re.search(r"@[0-9a-f]{40}$", ref) is not None, f"{f.name}: action not pinned to a full commit SHA: {ref}")

    check(tf.get("permissions") == {"contents": "read"}, f"workflow permissions must be contents: read, got {tf.get('permissions')}")
    for name, job in jobs.items():
        idt = (job.get("permissions") or {}).get("id-token")
        check((idt == "write") == (name in ("terraform-plan", "terraform-apply")), f"{name}: id-token: write only for plan/apply, got {idt}")

    for name, job in jobs.items():
        cond = str(job.get("if", ""))
        if name == "workflow-summary":
            check("always()" in cond, "summary job must use always() so it reports after failures")
        else:
            check(not re.search(r"always\(\)|failure\(\)|cancelled\(\)", cond), f"{name}: must not use always()/failure()/cancelled() in `if`")

    plan, apply_ = jobs["terraform-plan"], jobs["terraform-apply"]
    check(set(CHECKS) <= set(plan["needs"]), "plan must need all four check jobs")
    check(apply_["needs"] in (["terraform-plan"], "terraform-plan"), "apply must need exactly the plan job")
    check(set(jobs["workflow-summary"]["needs"]) == set(ORDER), "summary must need every other job")
    check(apply_.get("environment") == "lab", "apply must run in the 'lab' Environment")
    check("pull_request" not in str(apply_.get("if", "")), "apply condition must not mention pull_request")
    check("terraform apply" in step_text(apply_) and "tfplan" in step_text(apply_), "apply must apply the saved plan file")
    upload = [s for s in plan["steps"] if "upload-artifact" in str(s.get("uses", ""))]
    check(len(upload) == 1 and "has_changes" in str(upload[0].get("if", "")), "plan artifact upload must be conditional on a successful plan with changes")
    check(all("plan.log" not in str(s.get("with", "")) for s in upload), "plan.log must not be uploaded")
    check(all(not str(s.get("with", {}).get("path", "")).endswith("tfplan") for s in upload), "the unencrypted plan must not be uploaded")

    # ---------------------------------------------------------------- scenario matrix
    scenarios = [
        # description, ctx, forced failures, expected (plan, apply)
        ("pull request, same repo", context("pull_request", "12/merge"), {}, ("skipped", "skipped")),
        ("pull request, fork", context("pull_request", "12/merge", fork=True), {}, ("skipped", "skipped")),
        ("pull request, plan changes irrelevant", context("pull_request", "12/merge", has_changes="true"), {}, ("skipped", "skipped")),
        ("push to main, changes", context("push", "main"), {}, ("success", "success")),
        ("push to main, no changes", context("push", "main", has_changes="false"), {}, ("success", "skipped")),
        ("push to other branch", context("push", "feature"), {}, ("skipped", "skipped")),
        ("manual run on main", context("workflow_dispatch", "main"), {}, ("success", "skipped")),
        ("manual run on other branch", context("workflow_dispatch", "feature"), {}, ("skipped", "skipped")),
        ("push to main, plan fails", context("push", "main"), {"terraform-plan": "failure"}, ("failure", "skipped")),
    ]
    for chk in CHECKS:
        scenarios.append((f"push to main, {chk} fails", context("push", "main"), {chk: "failure"}, ("skipped", "skipped")))
        scenarios.append((f"pull request, {chk} fails", context("pull_request", "1/merge"), {chk: "failure"}, ("skipped", "skipped")))

    print(f"{'scenario':46} {'checks':8} {'plan':9} {'apply':9}")
    for desc, ctx, forced, (exp_plan, exp_apply) in scenarios:
        st = simulate(jobs, ctx, forced)
        checks_state = "ok" if all(st[c] == "success" for c in CHECKS) else "FAILED"
        print(f"{desc:46} {checks_state:8} {st['terraform-plan']:9} {st['terraform-apply']:9}")
        check(st["terraform-plan"] == exp_plan, f"[{desc}] plan expected {exp_plan}, got {st['terraform-plan']}")
        check(st["terraform-apply"] == exp_apply, f"[{desc}] apply expected {exp_apply}, got {st['terraform-apply']}")

    # ---------------------------------------------------------------- exhaustive invariants
    combos = 0
    for event, ref, has_changes, fork, plan_result in itertools.product(
        ["pull_request", "push", "workflow_dispatch", "schedule", "workflow_run"],
        ["main", "feature", "12/merge"],
        ["true", "false", ""],
        [False, True],
        ["success", "failure"],
    ):
        for failed in itertools.chain.from_iterable(itertools.combinations(CHECKS, n) for n in range(5)):
            forced = {c: "failure" for c in failed}
            forced["terraform-plan"] = plan_result
            st = simulate(jobs, context(event, ref, fork=fork, has_changes=has_changes), forced)
            combos += 1
            applied = st["terraform-apply"] == "success"
            planned = st["terraform-plan"] != "skipped"
            if applied:
                check(event == "push" and ref == "main" and has_changes == "true" and plan_result == "success" and not failed,
                      f"apply ran unexpectedly: event={event} ref={ref} changes={has_changes} plan={plan_result} failed={failed}")
            if event == "pull_request":
                check(not planned and not applied, f"pull_request reached plan/apply: ref={ref} failed={failed}")
            if failed:
                check(not planned, f"plan ran although {failed} failed (event={event})")
            if st["terraform-plan"] == "failure":
                check(st["terraform-apply"] == "skipped", "apply ran after a failed plan")
    print(f"\nexhaustive invariants checked over {combos} combinations")

    if failures:
        print("\nFAILED:")
        for f in dict.fromkeys(failures):  # de-duplicate, keep order
            print(f"  - {f}")
        return 1
    print("workflow policy and event/dependency tests: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
