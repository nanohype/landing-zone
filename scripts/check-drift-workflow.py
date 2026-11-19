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
    it would present `environment:drift` and receive the role map.
  - drift.yml itself gaining one of those triggers.

The role map itself, a secret holding every account's id, must also stay out
of drift.yml's guard job as anything but a presence test, since that job
declares no environment.

Where and when drift.yml masks the map (`scripts/mask-aws-ids.sh
DRIFT_PLAN_ROLE_ARNS` as the first command of each job's first step that
receives it) is not checked here: scripts/check-workflow-id-masking.py owns
that rule for every workflow, drift.yml included, and one owner keeps the two
gates from disagreeing about it.

WHAT IT CHECKS

  1. No workflow but drift.yml declares the `drift` environment, in any letter
     case, as a string or `{name: ...}`, and no workflow declares an
     environment from an expression that mentions it.
  2. drift.yml triggers on `schedule` and `workflow_dispatch` only.
  3. In drift.yml, `secrets.DRIFT_PLAN_ROLE_ARNS` and `vars.DRIFT_PLAN_ROLE_ARNS`
     appear only in a step's `env` map. A job that reads the secret's value
     declares `environment: drift`; the one job that declares no environment
     (refuse-inherited-config) may only compare each against '' so that only
     `true` or `false` reaches its step.
  4. Floor: at least two jobs declaring `environment: drift` read the secret,
     and at least one no-environment guard job compares it, so a scan that
     stopped recognising drift.yml's shape cannot report a pass.

Parsed with a real YAML parser, with line numbers kept, so a finding names the
file and line.

Exit 0 = clean. Exit 1 = a violation, or a scan that could not see its inputs.
"""

from __future__ import annotations

import re
import sys
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

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
DRIFT = WORKFLOWS / "drift.yml"

SECRET = re.compile(r"\bsecrets\.DRIFT_PLAN_ROLE_ARNS\b")
VARIABLE = re.compile(r"\bvars\.DRIFT_PLAN_ROLE_ARNS\b")
# The only form a job with no environment may use: a comparison whose result is
# true or false, never the value.
PRESENCE_ONLY = re.compile(
    r"^\$\{\{\s*(?:secrets|vars)\.DRIFT_PLAN_ROLE_ARNS\s*!=\s*''\s*\}\}$"
)
ALLOWED_TRIGGERS = {"schedule", "workflow_dispatch"}


class LDict(dict):
    line = 0


class LList(list):
    line = 0


class LineLoader(yaml.SafeLoader):
    pass


def _mapping(loader, node):
    d = LDict(loader.construct_mapping(node, deep=True))
    d.line = node.start_mark.line + 1
    return d


def _sequence(loader, node):
    s = LList(loader.construct_sequence(node, deep=True))
    s.line = node.start_mark.line + 1
    return s


LineLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)
LineLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_SEQUENCE_TAG, _sequence)


def strings(value):
    """Every string anywhere inside a parsed YAML value."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for k, v in value.items():
            if isinstance(k, str):
                yield k
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)


def mentions(value, pattern: re.Pattern) -> bool:
    return any(pattern.search(s) for s in strings(value))


def environment_name(job: dict):
    env = job.get("environment")
    if isinstance(env, dict):
        env = env.get("name")
    return env


def line_of(obj, default: int = 1) -> int:
    return getattr(obj, "line", 0) or default


def key_line(path: Path, start: int, key: str) -> int:
    """The first line at or after `start` that sets `key:`; `start` if none."""
    lines = path.read_text().splitlines()
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*:")
    for n in range(start, len(lines) + 1):
        if pattern.match(lines[n - 1]):
            return n
    return start


def load(path: Path):
    try:
        return yaml.load(path.read_text(), Loader=LineLoader)
    except (OSError, yaml.YAMLError) as e:
        return e


def main() -> int:
    findings: list[str] = []

    def bad(path: Path, line: int, msg: str) -> None:
        rel = path.relative_to(ROOT).as_posix()
        findings.append(f"::error file={rel},line={line}::{rel}:{line}: {msg}")

    workflows = sorted(
        p for p in WORKFLOWS.glob("*") if p.suffix in (".yml", ".yaml") and p.is_file()
    ) if WORKFLOWS.is_dir() else []
    if not DRIFT.is_file() or len(workflows) < 3:
        print(
            f"::error::found {len(workflows)} workflow(s) and drift.yml "
            f"{'present' if DRIFT.is_file() else 'missing'} under .github/workflows; "
            "this gate did not see its inputs and refuses to report a pass."
        )
        return 1

    # 1. Only drift.yml declares the drift environment.
    for path in workflows:
        doc = load(path)
        if not isinstance(doc, dict):
            print(f"::error::{path.relative_to(ROOT)} could not be parsed: {doc}")
            return 1
        if path == DRIFT:
            continue
        for job_id, job in (doc.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            name = environment_name(job)
            if isinstance(name, str) and "drift" in name.lower():
                bad(
                    path,
                    key_line(path, line_of(job), "environment"),
                    f"job '{job_id}' declares environment '{name}'. The drift "
                    "environment's branch policy admits by ref, so a workflow on main "
                    "naming it (a pull_request_target, workflow_run or issue_comment "
                    "trigger runs with ref main) would receive the staging and "
                    "production plan roles and DRIFT_PLAN_ROLE_ARNS. Only drift.yml "
                    "may declare it.",
                )
            if mentions(job, SECRET) or mentions(job, VARIABLE):
                bad(
                    path,
                    line_of(job),
                    f"job '{job_id}' reads DRIFT_PLAN_ROLE_ARNS, which belongs to "
                    "drift.yml's jobs alone.",
                )

    drift = load(DRIFT)
    jobs = drift.get("jobs") or {}

    # 2. drift.yml's triggers.
    on = drift.get("on", drift.get(True))
    triggers = set(on) if isinstance(on, dict) else {on} if isinstance(on, str) else set(on or [])
    extra = triggers - ALLOWED_TRIGGERS
    if extra or not triggers:
        bad(
            DRIFT,
            line_of(on, 1),
            f"drift.yml triggers on {sorted(map(str, triggers))}; only schedule and "
            "workflow_dispatch are allowed. Its jobs declare the main-only drift "
            "environment, and a trigger such as pull_request_target, workflow_run or "
            "issue_comment runs with ref main for whoever caused it.",
        )

    # 3, per job, and the counts the floor reads.
    drift_jobs = 0
    guard_jobs = 0
    for job_id, job in jobs.items():
        if not isinstance(job, dict):
            continue
        env_name = environment_name(job)
        reads_secret = mentions(job, SECRET)
        reads_variable = mentions(job, VARIABLE)
        if not (reads_secret or reads_variable):
            continue

        # References outside a step's env map: job-level env, `with:`, `run:`,
        # `if:` and the rest.
        outside = {k: v for k, v in job.items() if k != "steps"}
        if mentions(outside, SECRET) or mentions(outside, VARIABLE):
            bad(
                DRIFT,
                line_of(job),
                f"job '{job_id}' names DRIFT_PLAN_ROLE_ARNS outside a step's env map "
                "(a job-level env reaches steps that run before the mask step).",
            )
        steps = job.get("steps") or []
        for step in steps:
            if not isinstance(step, dict):
                continue
            rest = {k: v for k, v in step.items() if k != "env"}
            if mentions(rest, SECRET) or mentions(rest, VARIABLE):
                bad(
                    DRIFT,
                    line_of(step),
                    f"job '{job_id}', step '{step.get('name', step.get('uses', '?'))}' "
                    "names DRIFT_PLAN_ROLE_ARNS outside its env map. Expanded into a "
                    "script or an input, its value is printed before any mask exists.",
                )

        if env_name is None:
            # The guard: presence only, never the value.
            guard_jobs += 1
            for step in steps:
                for key, value in (step.get("env") or {}).items():
                    if not isinstance(value, str):
                        continue
                    if (SECRET.search(value) or VARIABLE.search(value)) and not PRESENCE_ONLY.match(
                        value.split("#")[0].strip()
                    ):
                        bad(
                            DRIFT,
                            line_of(step.get("env"), line_of(step)),
                            f"job '{job_id}' declares no environment, so it sees "
                            f"repository and organization values; its env '{key}' must "
                            "compare DRIFT_PLAN_ROLE_ARNS against '' and pass only true "
                            "or false, never the value.",
                        )
            continue

        if not (isinstance(env_name, str) and env_name.lower() == "drift"):
            bad(
                DRIFT,
                line_of(job),
                f"job '{job_id}' reads DRIFT_PLAN_ROLE_ARNS but declares environment "
                f"'{env_name}', not 'drift'. The secret lives on the drift environment, "
                "whose branch policy admits main only.",
            )
            continue
        if reads_variable:
            bad(
                DRIFT,
                line_of(job),
                f"job '{job_id}' reads vars.DRIFT_PLAN_ROLE_ARNS. The map is a secret; "
                "a variable is never masked.",
            )
        if reads_secret:
            drift_jobs += 1

    # 4. The floor.
    if not findings and (drift_jobs < 2 or guard_jobs < 1):
        print(
            f"::error::drift.yml has {drift_jobs} job(s) on the drift environment reading "
            f"DRIFT_PLAN_ROLE_ARNS and {guard_jobs} presence-only guard job(s) (expected "
            "at least 2 and 1). The scan did not see what it checks and refuses to report "
            "a pass."
        )
        return 1

    if findings:
        print("\n".join(findings))
        print(
            f"\n{len(findings)} finding(s). See the docstring of "
            "scripts/check-drift-workflow.py and docs/operations.md (drift.yml)."
        )
        return 1

    print(
        f"OK: {len(workflows)} workflow(s) read; only drift.yml declares the drift "
        f"environment; drift.yml triggers on {sorted(map(str, triggers))}; "
        f"{drift_jobs} job(s) on the drift environment read DRIFT_PLAN_ROLE_ARNS from "
        f"step env maps only; {guard_jobs} guard job(s) see presence only (where each "
        "job masks it is check-workflow-id-masking.py's to hold)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
