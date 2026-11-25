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
                                       in any finding; accept each edit the
                                       rules permit; refuse each shortfall by
                                       the floor alone; and require each way
                                       of breaking the self-test to fail it,
                                       and the gate to stop without PyYAML
                                       or the masking gate

Exit 0 = clean. Exit 1 = a violation, or a scan that could not see its inputs.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock

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

MASKING_GATE = HERE / "check-workflow-id-masking.py"


def load_masking(path: Path):
    """The masking gate's module, loaded from path; exit 1 if it cannot be.

    This gate reads expressions with that gate's YAML loader and tokeniser, so both
    gates read a workflow the same way, and it refuses to report a pass without them."""
    spec = importlib.util.spec_from_file_location("check_workflow_id_masking", path)
    try:
        if spec is None or spec.loader is None:
            raise ImportError(f"no loader reads {path.name}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except (ImportError, OSError, SyntaxError) as e:
        print(f"FAIL: {path.name} could not be loaded ({type(e).__name__}); this gate reads "
              "expressions with its tokeniser and refuses to report a pass without it.",
              file=sys.stderr)
        sys.exit(1)
    return module


masking = load_masking(MASKING_GATE)
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
    ("another workflow names the role map in an expression it cannot read", "ci.yml",
     CI_PLAN_ENV, CI_PLAN_ENV + "    env:\n      MAP: ${{ secrets.DRIFT_PLAN_ROLE_ARNS ' }}\n",
     None),
    # The two below park drift.yml's own trigger block under a key no workflow reads,
    # so the file still parses with `on:` in the form each case writes.
    ("drift.yml's triggers written as one string", "drift.yml", DRIFT_ON,
     "on: pull_request_target\nparked:\n  schedule:\n", r"^on: pull_request_target$"),
    ("drift.yml's triggers written as a list", "drift.yml", DRIFT_ON,
     "on: [schedule, pull_request_target]\nparked:\n  schedule:\n", r"^on: \["),
    ("a dispatch choice input that lists no options", "deploy.yml", DEPLOY_ENV_CHOICE,
     "      component:", r"^\s+environment: \$\{\{ inputs\.environment \}\}"),
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


# Edits the rules permit, each to be accepted with nothing found and the floor met:
# (name, file, old, new).
ACCEPTED = [
    ("a job in another workflow that is not a mapping", "ci.yml", "jobs:\n", "jobs:\n  stray: 1\n"),
    ("a drift.yml job that is not a mapping", "drift.yml", "jobs:\n", "jobs:\n  stray: 1\n"),
    # Unreadable, but naming no role map: the masking gate reports it, not this one.
    ("an expression it cannot read that names no role map", "ci.yml", CI_PLAN_ENV,
     CI_PLAN_ENV + "    env:\n      OTHER: ${{ github.ref ' }}\n"),
]

# Edits that leave the scan short of what it checks, each to be refused by the floor
# with no finding: (name, file, old, new). new None deletes the file.
FLOORS = [
    ("the guard job reads the role map from vars alone", "drift.yml",
     "INHERITED_SECRET: ${{ secrets.DRIFT_PLAN_ROLE_ARNS != '' }}",
     "INHERITED_SECRET: ${{ vars.DRIFT_PLAN_ROLE_ARNS != '' }}"),
    ("a drift-environment job reads the role map from vars alone", "drift.yml",
     "DRIFT_PLAN_ROLE_ARNS: ${{ secrets.DRIFT_PLAN_ROLE_ARNS }}\n          ROLE_MAP_VARIABLE:",
     "DRIFT_PLAN_ROLE_ARNS: ${{ vars.DRIFT_PLAN_ROLE_ARNS }}\n          ROLE_MAP_VARIABLE:"),
    ("drift.yml is gone", "drift.yml", None, None),
]

# The mutations this self-test holds. A self-test over fewer cannot report a pass, so a
# case is removed only with this number lowered beside it.
MIN_MUTATIONS = 19

# One self-test case's result: (its name, why it failed or None, lines to show).
Outcome = tuple[str, "str | None", list]


def checked_edit(base: Path, fname: str, old, new):
    """check() over base with one edit to fname, undone after: (result, text before, text
    after, None), or (None, None, None, why the edit could not be made). old None writes
    new as the whole file; new None deletes the file."""
    target = base / WORKFLOWS_REL / fname
    text = target.read_text() if target.is_file() else None
    found = 1 if old is None else (text or "").count(old)
    if found != 1:
        return None, None, None, f"anchor {old[:50]!r} found {found} time(s) in {fname}"
    mutated = new if old is None or new is None else (text or "").replace(old, new)
    if mutated is None:
        target.unlink()
    else:
        target.write_text(mutated)
    try:
        return check(base), text, mutated, None
    finally:
        if text is None:
            target.unlink()
        else:
            target.write_text(text)


def mutation_outcome(base: Path, case) -> Outcome:
    """One mutation, rejected at its line with no account id in any finding, or why not."""
    name, fname, old, new, expect = case
    res, text, mutated, problem = checked_edit(base, fname, old, new)
    if problem:
        return name, problem, []
    planted = {m.group(1) for m in masking.ID_LITERAL.finditer(mutated)
               if not masking.placeholder(m.group(1))} \
        - set(masking.ID_LITERAL.findall(text or ""))
    leaked = masking.leaked_ids(res.findings, planted)
    if leaked:
        # The messages are not shown: the point is that they carry an id.
        return name, (f"{len(leaked)} finding(s) quote an account id, at {leaked}; a finding "
                      "is published as an annotation and must say <account id> instead"), []
    rel = f"{WORKFLOWS_REL}/{fname}"
    if expect is None:
        first = mutated.count("\n", 0, mutated.index(new)) + 1
        old_lines = set((old or "").splitlines())
        wanted = {first + i for i, ln in enumerate(new.splitlines())
                  if ln not in old_lines} or {first}
    else:
        wanted = {i + 1 for i, ln in enumerate(mutated.splitlines()) if re.search(expect, ln)}
    cited = {ln for r, ln, _ in res.findings if r == rel}
    shown = [f"{r}:{ln}: {msg[:110]}" for r, ln, msg in res.findings]
    if not res.findings:
        return name, "not rejected", []
    if not cited & wanted:
        return name, (f"rejected, but cited {sorted(cited) or 'no line'} in {rel}, not the "
                      f"mutated line(s) {sorted(wanted)}"), shown
    hit = next(f for f in res.findings if f[0] == rel and f[1] in wanted)
    return name, None, [f"{hit[0]}:{hit[1]}: {hit[2][:90]}"]


def accepted_outcome(base: Path, case) -> Outcome:
    """One permitted edit, accepted with nothing found and the floor met, or why not."""
    name, fname, old, new = case
    res, _, _, problem = checked_edit(base, fname, old, new)
    label = f"accepted: {name}"
    if problem:
        return label, problem, []
    if res.findings:
        return label, "rejected", [f"{r}:{ln}: {msg[:110]}" for r, ln, msg in res.findings]
    return label, floor_message(res), []


def floor_outcome(base: Path, case) -> Outcome:
    """One shortfall, refused by the floor with no finding, or why not."""
    name, fname, old, new = case
    res, _, _, problem = checked_edit(base, fname, old, new)
    label = f"floor: {name}"
    if problem:
        return label, problem, []
    if res.findings:
        return label, "rejected by a finding, not the floor", [
            f"{r}:{ln}: {msg[:110]}" for r, ln, msg in res.findings]
    if not floor_message(res):
        return label, "the floor passed", []
    return label, None, []


def expect(ok: bool, message: str) -> list[str]:
    """[message] when a check of the self-test's own failed, else nothing."""
    return [] if ok else [message]


def exit_status(call, *args) -> int | str | None:
    """The status call(*args) exits with, or None when it returns."""
    try:
        call(*args)
    except SystemExit as e:
        return e.code
    return None


def rejecting_check(root: Path) -> Result:
    """A check() that rejects every tree, for a baseline the self-test must refuse."""
    res = Result()
    res.findings.append((f"{WORKFLOWS_REL}/ci.yml", 1, "planted"))
    return res


def broken_runs() -> list:
    """Each way of breaking this self-test, which must then fail: (name, the patch that
    breaks it, the mutations it runs over, whether it runs the meta stage, words its
    output must hold)."""
    literal = MUTATIONS[0]
    # A finding that quotes workflow text carrying an id: a parse error's would not do,
    # since parse_error() leaves out the parser's excerpt whether redaction is on or off.
    quoting = next(m for m in MUTATIONS
                   if m[0] == "a dispatch choice input offers drift beside an account id")
    one = [literal]
    gone = "this text is in no workflow"
    return [
        ("a baseline the gate rejects", mock.patch.dict(globals(), {"check": rejecting_check}),
         one, False, "FAIL [unmutated]: the gate rejects the workflows as they are"),
        ("a mutation whose anchor is gone", contextlib.nullcontext(),
         [("gone", "ci.yml", gone, "", None)], False, "found 0 time(s)"),
        ("a finding that quotes an account id",
         mock.patch.object(masking, "redact", lambda text: text), [quoting], False,
         "quote an account id"),
        ("a mutation the gate accepts", contextlib.nullcontext(),
         [(literal[0], literal[1], literal[2], literal[2], None)], False, "not rejected"),
        ("a rejection at another line", contextlib.nullcontext(),
         [(*literal[:4], r"(?!)")], False, "not the mutated line(s)"),
        ("a permitted edit the gate rejects",
         mock.patch.dict(globals(), {"ACCEPTED": [("x", *literal[1:4])]}), one, False,
         "FAIL [accepted: x]: rejected"),
        ("a permitted edit whose anchor is gone",
         mock.patch.dict(globals(), {"ACCEPTED": [("x", "ci.yml", gone, "")]}), one, False,
         "FAIL [accepted: x]: anchor"),
        ("a shortfall the floor lets pass",
         mock.patch.dict(globals(), {"FLOORS": [("x", "ci.yml", CI_PLAN_ENV, CI_PLAN_ENV)]}),
         one, False, "FAIL [floor: x]: the floor passed"),
        ("a shortfall refused by a finding instead",
         mock.patch.dict(globals(), {"FLOORS": [("x", *literal[1:4])]}), one, False,
         "FAIL [floor: x]: rejected by a finding"),
        ("a shortfall whose anchor is gone",
         mock.patch.dict(globals(), {"FLOORS": [("x", "ci.yml", gone, "")]}), one, False,
         "FAIL [floor: x]: anchor"),
        ("fewer mutations than it holds", contextlib.nullcontext(), one, False,
         "refusing to report a pass"),
        ("a meta stage that reports a problem",
         mock.patch.dict(globals(), {"meta_problems": lambda: ["planted"]}), one, True,
         "FAIL [meta]: planted"),
    ]


def meta_problems() -> list[str]:
    """Why this self-test cannot be trusted, or nothing. Each way of breaking it must fail
    it saying so; the gate must load the masking gate beside it, and stop with exit 1
    where it cannot load one or PyYAML; and it must refuse an argument it does not take."""
    # The reporter itself, checked without it: a failed check must yield its message.
    problems = ["expect() does not report a failed check"] * (expect(False, "x") != ["x"])
    for name, patch, mutations, meta, says in broken_runs():
        printed = io.StringIO()
        with patch, contextlib.redirect_stdout(printed), contextlib.redirect_stderr(printed):
            code = self_test(mutations, meta=meta)
        problems += expect(code == 1 and says in printed.getvalue(),
                           f"a self-test over {name} exited {code}, not 1 saying {says!r}")
    problems += expect(exit_status(load_masking, MASKING_GATE) is None,
                       "the masking gate beside this file did not load")
    with tempfile.TemporaryDirectory(prefix="drift-workflow-load-") as tmp:
        for name, path in (("a masking gate that is not there", Path(tmp) / MASKING_GATE.name),
                           ("a masking gate no loader reads", Path(tmp) / "masking.txt")):
            printed = io.StringIO()
            with contextlib.redirect_stderr(printed):
                status = exit_status(load_masking, path)
            problems += expect(status == 1 and "could not be loaded" in printed.getvalue(),
                               f"{name}: the gate exited {status}, not 1 saying it could not "
                               "be loaded")
    this = str(Path(__file__).resolve())
    proc = subprocess.run(
        [sys.executable, "-c", ("import runpy, sys; sys.modules['yaml'] = None; "
                                f"runpy.run_path({this!r}, run_name='without_yaml')")],
        capture_output=True, text=True, timeout=60, check=False)
    problems += expect(proc.returncode == 1 and "PyYAML is not installed" in proc.stderr,
                       f"without PyYAML the gate exited {proc.returncode}, not 1")
    proc = subprocess.run([sys.executable, this, "--no-such-flag"], capture_output=True,
                          text=True, timeout=60, check=False)
    problems += expect(proc.returncode == 2 and "usage:" in proc.stderr,
                       f"an argument the gate does not take: exited {proc.returncode}, not 2")
    return problems


def self_test(mutations: list | None = None, meta: bool = True) -> int:
    """0 when the unmutated workflows are accepted, each mutation is rejected at the line
    it changes with no account id in any finding, each permitted edit is accepted, each
    shortfall is refused by the floor alone, and there are at least MIN_MUTATIONS
    mutations; 1 otherwise. With meta, meta_problems() must also find nothing."""
    mutations = MUTATIONS if mutations is None else mutations
    with tempfile.TemporaryDirectory(prefix="drift-workflow-") as tmp:
        base = Path(tmp)
        (base / WORKFLOWS_REL).mkdir(parents=True)
        for p in (ROOT / WORKFLOWS_REL).glob("*.y*ml"):
            shutil.copy(p, base / WORKFLOWS_REL / p.name)
        clean = check(base)
        refused = [f"{rel}:{ln}: {msg[:120]}" for rel, ln, msg in clean.findings] \
            + [m for m in (floor_message(clean),) if m]
        if refused:
            print("FAIL [unmutated]: the gate rejects the workflows as they are:",
                  file=sys.stderr)
            for line in refused:
                print(f"  {line}", file=sys.stderr)
            return 1
        outcomes = [mutation_outcome(base, case) for case in mutations] \
            + [accepted_outcome(base, case) for case in ACCEPTED] \
            + [floor_outcome(base, case) for case in FLOORS]
    failed = [o for o in outcomes if o[1]]
    for name, why, shown in outcomes:
        if why:
            print(f"FAIL [{name}]: {why}", file=sys.stderr)
            for line in shown:
                print(f"    {line}", file=sys.stderr)
        else:
            print(f"ok [{name}]" + (f": {shown[0]}" if shown else ""))
    problems = meta_problems() if meta else []
    for problem in problems:
        print(f"FAIL [meta]: {problem}", file=sys.stderr)
    if failed or problems:
        print(f"check-drift-workflow self-test FAILED: {len(failed)} of {len(outcomes)} "
              f"case(s), and {len(problems)} meta problem(s)", file=sys.stderr)
        return 1
    if len(mutations) < MIN_MUTATIONS:
        print(f"self-test ran {len(mutations)} mutation(s), fewer than the {MIN_MUTATIONS} it "
              "holds; refusing to report a pass", file=sys.stderr)
        return 1
    print(f"check-drift-workflow self-test passed ({len(mutations)} mutations rejected at "
          "the mutated line with no account id in any finding, "
          f"{len(ACCEPTED)} permitted edits accepted, {len(FLOORS)} shortfalls refused by "
          "the floor, unmutated workflows accepted"
          + ("; the self-test's own failures reported, and the gate stops without PyYAML or "
             "the masking gate and refuses an argument it does not take" if meta else "")
          + ").")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:]:
        print("usage: check-drift-workflow.py [--self-test]", file=sys.stderr)
        sys.exit(2)
    sys.exit(main())
