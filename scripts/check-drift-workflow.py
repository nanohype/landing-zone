#!/usr/bin/env python3
"""The drift environment, and the role map it holds, reach drift.yml's own jobs only.

WHY THIS EXISTS

A staging or production plan role trusts exactly
`repo:nanohype/landing-zone:environment:drift`, and carries account-wide read
(every environment's Terraform state included). The control that keeps that
off pull requests and other branches is the `drift` GitHub Environment's
deployment-branch policy, which admits `main` only. Two things get past a
branch policy without touching it:

  - a different workflow ON MAIN that names `environment: drift`. A branch
    policy admits by ref, and a workflow triggered by `pull_request_target`,
    `workflow_run` or `issue_comment` runs with ref main whoever caused it, so
    it would present `environment:drift` and receive the role map. Naming it
    need not be literal: `environment: ${{ github.event.pull_request.head.ref }}`
    is `drift` for a pull request from a branch called drift, and a dispatch
    input is `drift` if its form offers that value.
  - drift.yml itself gaining one of those triggers.

WHO OWNS WHAT

Where and how DRIFT_PLAN_ROLE_ARNS is read and masked (a secret read whole into
a step's env, masked first by `scripts/mask-aws-ids.sh DRIFT_PLAN_ROLE_ARNS`,
the no-environment guard job comparing it against '' and nothing else, the
in-environment variable guard) is scripts/check-workflow-id-masking.py's, which
holds every workflow to those rules, drift.yml included. This gate reads
expressions with that gate's tokeniser (imported, not copied), so the two
cannot disagree about whether a string reads the role map; it decides only
which workflows and jobs may.

WHAT IT CHECKS

  1. No workflow but drift.yml declares the `drift` environment, as a string or
     `{name: ...}`, in any letter case. Outside drift.yml an environment name
     may not be computed (`${{ }}`), with one exception: `${{ inputs.X }}` (or
     `github.event.inputs.X`) where X is a `workflow_dispatch` input of
     `type: choice` none of whose options names drift, and X is not also a
     `workflow_call` input (a caller passes any string). GitHub refuses a
     dispatch value outside a choice input's options, so that name is bounded
     by the options this gate reads. And no string anywhere in another
     workflow reads `secrets.DRIFT_PLAN_ROLE_ARNS` or `vars.DRIFT_PLAN_ROLE_ARNS`,
     in any spelling the expression language accepts.
  2. drift.yml triggers on `schedule` and `workflow_dispatch` only.
  3. In drift.yml, a job that reads DRIFT_PLAN_ROLE_ARNS declares
     `environment: drift`, or declares none (the guard job, whose form the
     masking gate holds). Never another environment.
  4. Floor: at least two jobs declaring `environment: drift` read the secret,
     and at least one job declaring no environment reads it, so a scan that
     stopped recognising drift.yml's shape cannot report a pass.

Parsed with a real YAML parser, with line numbers kept, so a finding names the
file and line.

A finding is printed as an `::error` annotation, which stays on the pull
request and in the public run log, and ci.yml runs this gate beside the
masking gate on every pull request. So every message goes through that gate's
redact() (a run of twelve or more digits other than a placeholder prints as
<account id>), workflow text it quotes is redacted before it is cut, and a
parse error is that gate's parse_error(), without PyYAML's pre-cut excerpt.
One gate redacting what the other prints in full would publish it all the same.

USAGE

  check-drift-workflow.py              check .github/workflows
  check-drift-workflow.py --self-test  mutate copies of the workflows in ways
                                       the rules forbid and require each to be
                                       rejected, citing the file and the
                                       mutated line, with no account id (nor
                                       the head or tail of one it planted)
                                       in any finding

Exit 0 = clean. Exit 1 = a violation, or a scan that could not see its inputs.
"""

from __future__ import annotations

import importlib.util
import re
import shutil
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "FAIL: PyYAML is not installed, so this gate cannot read the workflows. "
        "Refusing to report a pass over files it could not parse.",
        file=sys.stderr,
    )
    sys.exit(1)

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
WORKFLOWS_REL = ".github/workflows"
NAME = "DRIFT_PLAN_ROLE_ARNS"
ALLOWED_TRIGGERS = {"schedule", "workflow_dispatch"}

# The masking gate's YAML loader and expression reader, so both gates read a
# workflow the same way.
_spec = importlib.util.spec_from_file_location(
    "check_workflow_id_masking", HERE / "check-workflow-id-masking.py")
if _spec is None or _spec.loader is None:
    print("FAIL: scripts/check-workflow-id-masking.py could not be loaded; this gate "
          "reads expressions with its tokeniser and refuses to report a pass without it.",
          file=sys.stderr)
    sys.exit(1)
masking = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(masking)
LDict = masking.LDict


def role_map_reads(value, line: int):
    """(context, line) for each read of DRIFT_PLAN_ROLE_ARNS from secrets or vars."""
    out = []

    def walk(v, ln, key=None):
        if isinstance(v, str):
            for expr, idx in masking.expressions(v, key == "if"):
                toks = masking.tokenize(expr)
                at = masking.line_in(v, ln, idx)
                if toks is None:
                    # Unreadable: the masking gate reports it when it names a
                    # context; here a mention of the name is enough to count it.
                    if NAME.lower() in expr.lower():
                        out.append(("unreadable", at))
                    continue
                for r in masking.refs(toks):
                    got = masking.resolve(r)
                    if got and got[0] in ("secrets", "vars") and got[1] \
                            and got[1].upper() == NAME:
                        out.append((got[0], at))
        elif isinstance(v, LDict):
            for k, sub in v.items():
                kl = v.key_lines.get(k, v.line)
                if isinstance(k, str):
                    walk(k, kl)
                walk(sub, v.value_lines.get(k, kl), k)
        elif isinstance(v, list):
            for sub in v:
                walk(sub, getattr(sub, "line", 0) or ln)

    walk(value, line)
    return out


def environment_of(job):
    """(name, line) of a job's environment, or (None, line)."""
    env = job.get("environment")
    ln = job.key_lines.get("environment", job.line)
    if isinstance(env, LDict):
        ln = env.value_lines.get("name", env.key_lines.get("name", env.line))
        env = env.get("name")
    else:
        ln = job.value_lines.get("environment", ln)
    return env, ln


def triggers_of(doc):
    on = doc.get("on", doc.get(True))
    if isinstance(on, dict):
        return on, set(on)
    if isinstance(on, str):
        return on, {on}
    return on, set(on or [])


def bounded_input(doc, expr_text: str):
    """None when the computed name is `${{ inputs.X }}` over a drift-free choice
    input; otherwise the reason it is not."""
    expr = masking.exact_expr(expr_text)
    toks = masking.tokenize(expr) if expr is not None else None
    r = masking.sole(toks, masking.refs(toks)) if toks else None
    got = masking.resolve(r) if r else None
    if not (got and got[0] == "inputs" and got[1] and got[2] is None
            and len(r.path) == (3 if r.ctx == "github" else 1)):
        return "it is computed from something other than a single dispatch input"
    name = got[1]
    on, _ = triggers_of(doc)
    on = on if isinstance(on, dict) else {}

    def inputs_of(trigger):
        spec = on.get(trigger)
        inputs = spec.get("inputs") if isinstance(spec, dict) else None
        if not isinstance(inputs, dict):
            return None
        return next((v for k, v in inputs.items()
                     if isinstance(k, str) and k.lower() == name.lower()), None)

    if inputs_of("workflow_call") is not None:
        return (f"the input '{name}' is also a workflow_call input, which a calling "
                "workflow sets to any string")
    spec = inputs_of("workflow_dispatch")
    if not isinstance(spec, dict) or str(spec.get("type", "")).lower() != "choice":
        return (f"the input '{name}' is not a workflow_dispatch input of type choice, so "
                "its value is whatever the dispatcher types")
    options = spec.get("options")
    if not isinstance(options, list) or not options:
        return f"the choice input '{name}' lists no options this gate can read"
    named = [o for o in options if not isinstance(o, str) or "drift" in o.lower()]
    if named:
        return f"the choice input '{name}' offers {named!r}"
    return None


def load(path: Path):
    try:
        return masking.yaml.load(path.read_text(), Loader=masking.LineLoader)
    except (OSError, yaml.YAMLError) as e:
        return e


class Result:
    def __init__(self):
        self.findings: list[tuple[str, int, str]] = []
        self.workflows = 0
        self.drift_present = False
        self.drift_jobs = 0
        self.guard_jobs = 0
        self.triggers: set = set()


def check(root: Path) -> Result:
    res = Result()
    wf_dir = root / WORKFLOWS_REL
    drift_path = wf_dir / "drift.yml"
    paths = sorted(
        p for p in wf_dir.glob("*") if p.suffix in (".yml", ".yaml") and p.is_file()
    ) if wf_dir.is_dir() else []
    res.workflows = len(paths)
    res.drift_present = drift_path.is_file()

    def bad(path: Path, line: int, msg: str) -> None:
        res.findings.append((path.relative_to(root).as_posix(), line, masking.redact(msg)))

    drift = None
    for path in paths:
        doc = load(path)
        if not isinstance(doc, dict):
            bad(path, 1, masking.parse_error(doc) if isinstance(doc, Exception)
                else f"could not be parsed: {doc}")
            continue
        if path == drift_path:
            drift = doc
            continue

        # 1. Another workflow: no drift environment, no computed name it cannot
        # bound, and no read of the role map anywhere.
        jobs = doc.get("jobs") if isinstance(doc.get("jobs"), dict) else {}
        for job_id, job in jobs.items():
            if not isinstance(job, LDict):
                continue
            name, ln = environment_of(job)
            if name is None:
                continue
            text = str(name)
            if "${{" in text:
                why = bounded_input(doc, text)
                if why:
                    bad(path, ln,
                        f"job '{job_id}' declares its environment from {masking.quote(text, 70)}, and "
                        f"{why}. A computed name can evaluate to `drift`, whose branch "
                        "policy admits by ref: a workflow on main that a pull request, "
                        "comment or other run can trigger (pull_request_target, "
                        "issue_comment, workflow_run) would present environment:drift and "
                        "receive the staging and production plan roles and "
                        f"{NAME}. Name the environment literally, or from a "
                        "workflow_dispatch choice input whose options exclude drift.")
            elif "drift" in text.lower():
                bad(path, ln,
                    f"job '{job_id}' declares environment '{text}'. The drift "
                    "environment's branch policy admits by ref, so a workflow on main "
                    "naming it (a pull_request_target, workflow_run or issue_comment "
                    "trigger runs with ref main) would receive the staging and "
                    f"production plan roles and {NAME}. Only drift.yml may declare it.")
        for ctx, ln in role_map_reads(doc, 1):
            bad(path, ln,
                f"reads {NAME} ({ctx}), which belongs to drift.yml's jobs alone: it holds "
                "every account's plan role, and lives on the main-only drift environment.")

    if drift is None:
        return res
    jobs = drift.get("jobs") if isinstance(drift.get("jobs"), dict) else {}

    # 2. drift.yml's triggers.
    on, res.triggers = triggers_of(drift)
    extra = res.triggers - ALLOWED_TRIGGERS
    if extra or not res.triggers:
        bad(drift_path, drift.key_lines.get("on", drift.key_lines.get(True, 1)),
            f"drift.yml triggers on {sorted(map(str, res.triggers))}; only schedule and "
            "workflow_dispatch are allowed. Its jobs declare the main-only drift "
            "environment, and a trigger such as pull_request_target, workflow_run or "
            "issue_comment runs with ref main for whoever caused it.")

    # 3. Which drift.yml jobs may read the map, and the counts the floor reads.
    for job_id, job in jobs.items():
        if not isinstance(job, LDict):
            continue
        reads = role_map_reads(job, jobs.key_lines.get(job_id, job.line))
        if not reads:
            continue
        name, ln = environment_of(job)
        if name is None:
            if any(ctx == "secrets" for ctx, _ in reads):
                res.guard_jobs += 1
            continue
        if isinstance(name, str) and name.strip().lower() == "drift":
            if any(ctx == "secrets" for ctx, _ in reads):
                res.drift_jobs += 1
            continue
        bad(drift_path, ln,
            f"job '{job_id}' reads {NAME} but declares environment '{name}', not "
            "'drift'. The secret lives on the drift environment, whose branch policy "
            "admits main only; another environment's secrets fall back to the "
            "repository's, and its branch policy is not drift's.")
    return res


def floor_message(res: Result) -> str | None:
    if not res.drift_present or res.workflows < 3:
        return (f"found {res.workflows} workflow(s) and drift.yml "
                f"{'present' if res.drift_present else 'missing'} under .github/workflows; "
                "this gate did not see its inputs and refuses to report a pass.")
    if res.drift_jobs < 2 or res.guard_jobs < 1:
        return (f"drift.yml has {res.drift_jobs} job(s) on the drift environment reading "
                f"{NAME} and {res.guard_jobs} no-environment guard job(s) reading it "
                "(expected at least 2 and 1). The scan did not see what it checks and "
                "refuses to report a pass.")
    return None


def main() -> int:
    res = check(ROOT)
    for rel, line, msg in res.findings:
        print(f"::error file={rel},line={line}::{rel}:{line}: {msg}")
    if res.findings:
        print(f"\n{len(res.findings)} finding(s). See the docstring of "
              "scripts/check-drift-workflow.py and docs/operations.md (drift.yml).")
    floor = floor_message(res)
    if floor:
        print(f"::error::{floor}")
        return 1
    if res.findings:
        return 1
    print(
        f"OK: {res.workflows} workflow(s) read; only drift.yml declares the drift "
        f"environment, and no other workflow names an environment it cannot bound; "
        f"drift.yml triggers on {sorted(map(str, res.triggers))}; {res.drift_jobs} job(s) "
        f"on the drift environment and {res.guard_jobs} no-environment guard job(s) read "
        f"{NAME} (how each reads and masks it is check-workflow-id-masking.py's to hold)."
    )
    return 0


# --- self-test ----------------------------------------------------------------

CI_PLAN_ENV = "    environment: plan\n"
DEPLOY_ENV_CHOICE = ("        options:\n          - development\n          - staging\n"
                     "          - production\n      component:")
DEPLOY_JOB_ENV = "    environment: ${{ inputs.environment }}\n"
DRIFT_ON = "on:\n  schedule:\n"
DRIFT_SELECT_ENV = ("    timeout-minutes: 5\n    environment: drift\n    permissions:\n"
                    "      contents: read\n    outputs:\n      matrix: ${{ steps.select.outputs.matrix }}")
LABEL_WORKFLOW = """name: Label
on:
  pull_request_target:
permissions:
  contents: read
jobs:
  label:
    runs-on: ubuntu-latest
    environment: ${{ github.event.pull_request.head.ref }}
    permissions:
      id-token: write
    steps:
      - run: echo label
"""

# (name, file, old, new, expected line regex in the mutated file, or None for a
# changed line inside `new`). old None creates `file` with `new` as its text.
MUTATIONS = [
    ("another workflow names drift literally", "ci.yml", CI_PLAN_ENV,
     "    environment: drift\n", None),
    ("another workflow names drift in mixed case, as {name:}", "ci.yml", CI_PLAN_ENV,
     "    environment:\n      name: Drift\n", r"^\s+name: Drift$"),
    ("a pull_request_target workflow names its environment from the head ref",
     "label.yml", None, LABEL_WORKFLOW, r"^\s+environment: \$\{\{ github\.event"),
    ("a dispatch choice input offers drift", "deploy.yml", DEPLOY_ENV_CHOICE,
     DEPLOY_ENV_CHOICE.replace("          - production\n",
                               "          - production\n          - drift\n"),
     r"^\s+environment: \$\{\{ inputs\.environment \}\}"),
    ("the environment input is a free-form string", "destroy.yml",
     "      environment:\n        description: \"Target environment\"\n        required: true\n"
     "        type: choice\n",
     "      environment:\n        description: \"Target environment\"\n        required: true\n"
     "        type: string\n",
     r"^\s+environment: \$\{\{ inputs\.environment \}\}"),
    ("the environment input is also a workflow_call input", "deploy.yml",
     "on:\n  workflow_dispatch:\n",
     "on:\n  workflow_call:\n    inputs:\n      environment:\n        type: string\n"
     "  workflow_dispatch:\n",
     r"^\s+environment: \$\{\{ inputs\.environment \}\}"),
    ("an environment computed with format()", "deploy.yml", DEPLOY_JOB_ENV,
     "    environment: ${{ format('{0}', inputs.environment) }}\n", None),
    ("another workflow reads the role map through a mixed-case context", "ci.yml",
     CI_PLAN_ENV, CI_PLAN_ENV + "    env:\n      MAP: ${{ Secrets.DRIFT_PLAN_ROLE_ARNS != '' }}\n",
     None),
    ("another workflow reads the role map with index syntax", "e2e.yml",
     "    environment: e2e\n",
     "    environment: e2e\n    env:\n      MAP: ${{ secrets['DRIFT_PLAN_ROLE_ARNS'] }}\n", None),
    ("drift.yml gains pull_request_target", "drift.yml", DRIFT_ON,
     "on:\n  pull_request_target:\n  schedule:\n", r"^on:$"),
    ("a drift.yml job reads the map on another environment", "drift.yml", DRIFT_SELECT_ENV,
     DRIFT_SELECT_ENV.replace("    environment: drift\n", "    environment: plan\n"), None),
    # The findings below quote workflow text carrying an account id, and must
    # print <account id> in its place (the self-test fails any that does not).
    ("a workflow that does not parse, at a line carrying an account id", "ci.yml",
     CI_PLAN_ENV, CI_PLAN_ENV + "    env:\n      OWNER: 222233334444: x\n", r"^name: "),
    ("a workflow that does not parse, with an account id at the parser's excerpt cut",
     "ci.yml", CI_PLAN_ENV,
     CI_PLAN_ENV + "    env:\n      OWNER: x 222233334444 qqqqqqqqqqqqqqqqqqqqqqq: y\n",
     r"^name: "),
    ("a computed environment quoting an account id across the quote's cut", "deploy.yml",
     DEPLOY_JOB_ENV,
     ("    environment: ${{ format('{0}-{1}', inputs.environment, 'qqqqqqqqqqqqqqqqqq-"
      "222233334444') }}\n"), None),
    ("a dispatch choice input offers drift beside an account id", "deploy.yml",
     DEPLOY_ENV_CHOICE,
     DEPLOY_ENV_CHOICE.replace("          - production\n",
                               "          - production\n          - drift-222233334444\n"),
     r"^\s+environment: \$\{\{ inputs\.environment \}\}"),
]


def self_test() -> int:
    failures = ran = 0
    with tempfile.TemporaryDirectory(prefix="drift-workflow-") as tmp:
        base = Path(tmp)
        (base / WORKFLOWS_REL).mkdir(parents=True)
        for p in (ROOT / WORKFLOWS_REL).glob("*.y*ml"):
            shutil.copy(p, base / WORKFLOWS_REL / p.name)
        clean = check(base)
        if clean.findings or floor_message(clean):
            print("FAIL [unmutated]: the gate rejects the workflows as they are:",
                  file=sys.stderr)
            for rel, ln, msg in clean.findings:
                print(f"  {rel}:{ln}: {msg[:120]}", file=sys.stderr)
            if floor_message(clean):
                print(f"  {floor_message(clean)}", file=sys.stderr)
            return 1
        for name, fname, old, new, expect in MUTATIONS:
            ran += 1
            target = base / WORKFLOWS_REL / fname
            text = target.read_text() if old is not None else None
            if old is not None and text.count(old) != 1:
                print(f"FAIL [{name}]: anchor {old[:50]!r} found {text.count(old)} time(s) "
                      f"in {fname}", file=sys.stderr)
                failures += 1
                continue
            mutated = text.replace(old, new) if old is not None else new
            target.write_text(mutated)
            try:
                res = check(base)
            finally:
                if text is None:
                    target.unlink()
                else:
                    target.write_text(text)
            planted = {m.group(1) for m in masking.ID_LITERAL.finditer(mutated)
                       if not masking.placeholder(m.group(1))} \
                - set(masking.ID_LITERAL.findall(text or ""))
            leaked = masking.leaked_ids(res.findings, planted)
            if leaked:
                # The messages are not printed: the point is that they carry an id.
                print(f"FAIL [{name}]: {len(leaked)} finding(s) quote an account id, at "
                      f"{leaked}; a finding is published as an annotation and must say "
                      "<account id> instead", file=sys.stderr)
                failures += 1
                continue
            rel = f"{WORKFLOWS_REL}/{fname}"
            lines = mutated.splitlines()
            if expect is None:
                first = mutated.count("\n", 0, mutated.index(new)) + 1
                old_lines = set((old or "").splitlines())
                wanted = {first + i for i, ln in enumerate(new.splitlines())
                          if ln not in old_lines} or {first}
            else:
                wanted = {i + 1 for i, ln in enumerate(lines) if re.search(expect, ln)}
            cited = {ln for r, ln, _ in res.findings if r == rel}
            if not res.findings:
                print(f"FAIL [{name}]: not rejected", file=sys.stderr)
                failures += 1
            elif not (cited & wanted):
                print(f"FAIL [{name}]: rejected, but cited {sorted(cited) or 'no line'} in "
                      f"{rel}, not the mutated line(s) {sorted(wanted)}", file=sys.stderr)
                for r, ln, msg in res.findings:
                    print(f"    {r}:{ln}: {msg[:110]}", file=sys.stderr)
                failures += 1
            else:
                hit = next(f for f in res.findings if f[0] == rel and f[1] in wanted)
                print(f"ok [{name}]: {hit[0]}:{hit[1]}: {hit[2][:90]}")
    if failures:
        print(f"check-drift-workflow self-test FAILED: {failures} of {ran} mutation(s)",
              file=sys.stderr)
        return 1
    if ran < len(MUTATIONS):
        print("self-test ran fewer mutations than it lists; refusing to report a pass",
              file=sys.stderr)
        return 1
    print(f"check-drift-workflow self-test passed ({ran} mutations rejected at the "
          "mutated line with no account id in any finding, unmutated workflows accepted).")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:]:
        print("usage: check-drift-workflow.py [--self-test]", file=sys.stderr)
        sys.exit(2)
    sys.exit(main())
