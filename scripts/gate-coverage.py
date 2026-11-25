#!/usr/bin/env python3
"""Every Python script under scripts/ meets its coverage floor under the runs CI makes of it.

WHY THIS EXISTS

A gate's self-test plants the shapes its checks refuse, and check-gates-detect.py
proves each gate refuses one violation. Neither says what no run reaches. A line
no run reaches is a check that has never fired: it can be deleted, or turned
around, with every job green. Line and branch coverage under the runs CI already
makes measures that, and a floor keeps it from sliding.

WHAT IT RUNS, under coverage.py with branch measurement

  - every gate, scripts/check-*.py, as its CI job runs it: with no arguments;
  - every script under scripts/ that takes --self-test, with it (a shell script
    runs under bash, and its Python is measured where it runs as its own
    self-test).

check-gates-detect.py is one of the gates: it re-runs every gate against a tree
with one violation planted, and those runs are measured too, as subprocesses. A
gate or self-test that fails fails this run, since its coverage would say
nothing.

WHAT IT HOLDS

scripts/gate-coverage.toml sets the floor every tracked scripts/*.py meets, in
percent of its lines and of its branches, and each file held higher, with the
reason. A file no run executed is at 0%. A script's `if __name__ == "__main__"`
line never takes its import-side branch, and that one branch is marked expected
rather than excluded.

It refuses a floor outside 0-100, an override naming no tracked script, an
override below the floor, an override with no reason, and a key it does not read.

USAGE

  gate-coverage.py              run every gate and self-test under coverage, then
                                hold each script to its floor
  gate-coverage.py --self-test  hold the floor decisions to planted cases

Exit 0 = every script meets its floor. Exit 1 = a script below its floor, or a
gate or self-test that failed. Exit 2 = no verdict: coverage.py is missing, the
floors cannot be read, or the run measured nothing.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import tomllib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import NamedTuple
from unittest import mock

CANNOT_RUN = 2
ROOT = Path(__file__).resolve().parent.parent
FLOORS_REL = "scripts/gate-coverage.toml"
GATE = re.compile(r"scripts/check-[^/]+\.py")
RC = """\
[run]
branch = true
parallel = true
patch = subprocess
include = */scripts/*.py
data_file = {data}

[paths]
source =
    {root}/scripts/
    */scripts/

[report]
partial_also =
    if __name__ == .__main__.:
"""


class Floor(NamedTuple):
    line: float
    branch: float
    why: str = ""


class Measured(NamedTuple):
    lines: int
    covered_lines: int
    branches: int
    covered_branches: int


class FloorsError(Exception):
    """Why the floors cannot be used."""


def _percent(value, where: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 100:
        raise FloorsError(f"{where} is {value!r}, not a percentage from 0 to 100")
    return float(value)


def _table(value, keys: set[str], where: str) -> dict:
    """value as a table holding exactly keys."""
    if not isinstance(value, dict):
        raise FloorsError(f"{where} is not a table")
    unknown = sorted(set(value) - keys)
    if unknown:
        raise FloorsError(f"{where} has the unknown key(s) {', '.join(unknown)}")
    absent = sorted(keys - set(value))
    if absent:
        raise FloorsError(f"{where} has no {', '.join(absent)}")
    return value


def load_floors(text: str, tracked: set[str]) -> tuple[Floor, dict[str, Floor]]:
    """(the floor, each override by path) from the floors file's text."""
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise FloorsError(f"{FLOORS_REL} is not valid TOML ({e})") from e
    _table(data, {"floor", "override"}, FLOORS_REL)
    table = _table(data["floor"], {"line", "branch"}, f"{FLOORS_REL} [floor]")
    floor = Floor(_percent(table["line"], "[floor] line"), _percent(table["branch"], "[floor] branch"))
    if not isinstance(data["override"], dict):
        raise FloorsError(f"{FLOORS_REL} [override] is not a table")
    overrides: dict[str, Floor] = {}
    for rel, entry in data["override"].items():
        where = f'[override."{rel}"]'
        if rel not in tracked:
            raise FloorsError(f"{where} names no tracked Python script under scripts/")
        _table(entry, {"line", "branch", "why"}, where)
        why = entry["why"]
        if not isinstance(why, str) or not why.strip():
            raise FloorsError(f"{where} gives no reason; a file held apart says why")
        held = Floor(_percent(entry["line"], f"{where} line"),
                     _percent(entry["branch"], f"{where} branch"), why)
        if held.line < floor.line or held.branch < floor.branch:
            raise FloorsError(f"{where} sits below the floor; an override only holds a file "
                              "higher")
        overrides[rel] = held
    return floor, overrides


def findings(tracked: set[str], measured: dict[str, Measured], floor: Floor,
             overrides: dict[str, Floor]) -> list[str]:
    """Each tracked script below its floor, with its numbers."""
    out = []
    for rel in sorted(tracked):
        held = overrides.get(rel, floor)
        m = measured.get(rel)
        if m is None:
            out.append(f"{rel}: no run executed it (0% against a floor of {held.line:g}% of lines)")
            continue
        if m.covered_lines * 100 < held.line * m.lines:
            out.append(f"{rel}: {m.covered_lines} of {m.lines} lines "
                       f"({100 * m.covered_lines / m.lines:.1f}%), under its floor of {held.line:g}%")
        if m.branches and m.covered_branches * 100 < held.branch * m.branches:
            out.append(f"{rel}: {m.covered_branches} of {m.branches} branches "
                       f"({100 * m.covered_branches / m.branches:.1f}%), under its floor of "
                       f"{held.branch:g}%")
    return out


def tracked_scripts(root: Path) -> list[str]:
    proc = subprocess.run(["git", "-C", str(root), "ls-files", "scripts"],
                          capture_output=True, text=True, timeout=60, check=False)
    return [p for p in proc.stdout.splitlines() if p] if proc.returncode == 0 else []


def commands(root: Path, files: list[str], rcfile: Path) -> list[tuple[str, list[str]]]:
    """(label, argv) for every gate and every self-test, as CI runs each."""
    cover = [sys.executable, "-m", "coverage", "run", f"--rcfile={rcfile}"]
    out = [(rel, cover + [rel]) for rel in files if GATE.fullmatch(rel)]
    for rel in files:
        if rel.endswith((".py", ".sh")) and "--self-test" in (root / rel).read_text():
            out.append((f"{rel} --self-test", (cover + [rel] if rel.endswith(".py")
                                               else ["bash", rel]) + ["--self-test"]))
    return out


def run_all(root: Path, jobs: list[tuple[str, list[str]]]) -> list[str]:
    """Every command run in root; each that failed, with the end of its output."""
    def one(job: tuple[str, list[str]]) -> tuple[str, int, str, float]:
        start = time.monotonic()
        proc = subprocess.run(job[1], cwd=root, capture_output=True, text=True, timeout=1800,
                              check=False, stdin=subprocess.DEVNULL)
        return job[0], proc.returncode, (proc.stdout + proc.stderr)[-600:], time.monotonic() - start

    failed = []
    with ThreadPoolExecutor(max_workers=os.cpu_count() or 2) as pool:
        for label, code, tail, took in pool.map(one, jobs):
            print(f"{'ok  ' if code == 0 else 'FAIL'} {label} ({took:.0f}s)")
            if code:
                failed.append(f"{label} exited {code}:\n{tail}")
    return failed


def measure(root: Path, rcfile: Path, report: Path) -> dict[str, Measured]:
    """Each script's numbers from the combined data, keyed by its path under root."""
    base = [sys.executable, "-m", "coverage"]
    subprocess.run(base + ["combine", "-q", f"--rcfile={rcfile}"], cwd=root, check=False,
                   capture_output=True, timeout=600)
    subprocess.run(base + ["json", "-q", "-i", f"--rcfile={rcfile}", "-o", str(report)],
                   cwd=root, check=False, capture_output=True, timeout=600)
    if not report.is_file():
        return {}
    out = {}
    for name, entry in json.loads(report.read_text()).get("files", {}).items():
        path = (root / name).resolve()
        if path.is_relative_to(root.resolve()):
            s = entry["summary"]
            out[path.relative_to(root.resolve()).as_posix()] = Measured(
                s["num_statements"], s["covered_lines"], s["num_branches"], s["covered_branches"])
    return out


def main_check(root: Path = ROOT) -> int:
    try:
        import coverage  # noqa: F401  (run as python -m coverage; imported to fail early)
    except ImportError:
        print("Cannot run: coverage.py is not installed (pip install coverage).", file=sys.stderr)
        return CANNOT_RUN
    files = tracked_scripts(root)
    python = {rel for rel in files if rel.endswith(".py")}
    try:
        floor, overrides = load_floors((root / FLOORS_REL).read_text(), python)
    except (OSError, FloorsError) as e:
        print(f"Cannot run: {e}", file=sys.stderr)
        return CANNOT_RUN
    with tempfile.TemporaryDirectory(prefix="gate-coverage-") as tmp:
        rcfile = Path(tmp) / "rc"
        rcfile.write_text(RC.format(data=Path(tmp) / ".coverage", root=root.resolve()))
        failed = run_all(root, commands(root, files, rcfile))
        if failed:
            print("\n" + "\n\n".join(failed), file=sys.stderr)
            print(f"\n{len(failed)} gate(s) or self-test(s) failed; their coverage says nothing.",
                  file=sys.stderr)
            return 1
        measured = measure(root, rcfile, Path(tmp) / "coverage.json")
    if not measured:
        print("Cannot run: the run measured nothing. Refusing to report a pass.", file=sys.stderr)
        return CANNOT_RUN
    print()
    for rel in sorted(python):
        m, held = measured.get(rel), overrides.get(rel, floor)
        lines = f"{100 * m.covered_lines / m.lines:5.1f}%" if m and m.lines else "  -  "
        branches = f"{100 * m.covered_branches / m.branches:5.1f}%" if m and m.branches else "  -  "
        print(f"{rel:48} lines {lines} branches {branches}  floor {held.line:g}/{held.branch:g}")
    problems = findings(python, measured, floor, overrides)
    if problems:
        print("\n" + "\n".join(problems), file=sys.stderr)
        print(f"\n{len(problems)} script(s) under their floor. Reach the unrun lines with a case "
              f"in the script's self-test; {FLOORS_REL} says what each floor is.", file=sys.stderr)
        return 1
    print(f"\nOK: {len(python)} script(s) at or above their floor.")
    return 0


# --- self-test ----------------------------------------------------------------

FLOORS = """[floor]
line = 75
branch = 60

[override]
"""
TRACKED = {"scripts/a.py", "scripts/b.py"}

# (name, floors text, what the refusal says). Each must be refused.
FLOOR_REFUSALS = [
    ("a floor above 100", FLOORS.replace("line = 75", "line = 101"), "not a percentage"),
    ("a floor that is not a number", FLOORS.replace("line = 75", 'line = "75"'), "not a percentage"),
    ("a key the floors do not read", FLOORS.replace("[override]", "lines = 1\n[override]"),
     "unknown key(s) lines"),
    ("no branch floor", FLOORS.replace("branch = 60\n", ""), "has no branch"),
    ("no override table", FLOORS.replace("[override]\n", ""), "has no override"),
    ("not TOML", FLOORS + "[", "not valid TOML"),
    ("an override naming no tracked script",
     FLOORS + '"scripts/c.py" = { line = 100, branch = 100, why = "x" }\n', "names no tracked"),
    ("an override below the floor",
     FLOORS + '"scripts/a.py" = { line = 50, branch = 100, why = "x" }\n', "below the floor"),
    ("an override with no reason",
     FLOORS + '"scripts/a.py" = { line = 100, branch = 100 }\n', "has no why"),
    ("an override whose reason is blank",
     FLOORS + '"scripts/a.py" = { line = 100, branch = 100, why = " " }\n', "gives no reason"),
    ("an override table that is not a table", "override = 1\n" + FLOORS.replace("[override]\n", ""),
     "[override] is not a table"),
    ("an override that is not a table", FLOORS + '"scripts/a.py" = 100\n', "is not a table"),
]


def measured(lines: int, covered: int, branches: int = 0, covered_branches: int = 0) -> Measured:
    return Measured(lines, covered, branches, covered_branches)


# (name, measured, overrides, what a finding must say, or None for none at all).
VERDICTS = [
    ("both at their floors", {"scripts/a.py": measured(100, 75, 10, 6),
                              "scripts/b.py": measured(4, 3)}, {}, None),
    ("a script under its line floor", {"scripts/a.py": measured(100, 74, 10, 6),
                                       "scripts/b.py": measured(4, 4)}, {}, "74 of 100 lines"),
    ("a script under its branch floor", {"scripts/a.py": measured(100, 80, 10, 5),
                                         "scripts/b.py": measured(4, 4)}, {}, "5 of 10 branches"),
    ("a script no run executed", {"scripts/a.py": measured(100, 100)}, {},
     "scripts/b.py: no run executed it"),
    ("a script held higher", {"scripts/a.py": measured(100, 99, 10, 10),
                              "scripts/b.py": measured(4, 4)},
     {"scripts/a.py": Floor(100, 100, "x")}, "99 of 100 lines"),
]


# Tiny repositories main_check runs over end to end: (name, files, exit status, words it
# must print). A gate whose branch no run takes is under the branch floor.
GATE_OK = "print('ok')\n"
GATE_UNDER = "import sys\nif len(sys.argv) > 5:\n    print('never')\nprint('ok')\n"
REPOS = [
    ("a gate at its floor", {"scripts/check-x.py": GATE_OK, FLOORS_REL: FLOORS}, 0,
     "1 script(s) at or above their floor"),
    ("a gate under its floor", {"scripts/check-x.py": GATE_UNDER, FLOORS_REL: FLOORS}, 1,
     "1 of 2 branches"),
    ("a gate that fails", {"scripts/check-x.py": "raise SystemExit(1)\n", FLOORS_REL: FLOORS}, 1,
     "their coverage says nothing"),
    ("floors that cannot be read", {"scripts/check-x.py": GATE_OK, FLOORS_REL: "["}, CANNOT_RUN,
     "not valid TOML"),
    ("nothing to measure", {"scripts/x.sh": "true\n", FLOORS_REL: FLOORS}, CANNOT_RUN,
     "measured nothing"),
]


def repo_outcomes(scratch: Path) -> list[str]:
    """Why main_check did not exit as each tiny repository requires, or nothing; and the
    refusal to run without coverage.py."""
    failures = []
    for n, (name, files, status, says) in enumerate(REPOS):
        root = scratch / f"repo-{n}"
        for rel, text in files.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text)
        subprocess.run(["git", "init", "-q", str(root)], check=True, capture_output=True,
                       timeout=60)
        subprocess.run(["git", "-C", str(root), "add", "."], check=True, capture_output=True,
                       timeout=60)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = main_check(root)
        if code != status or says not in out.getvalue():
            failures.append(f"[{name}] main_check exited {code}, not {status} saying {says!r}")
    out = io.StringIO()
    with mock.patch.dict(sys.modules, {"coverage": None}), contextlib.redirect_stderr(out):
        code = main_check(scratch)
    if code != CANNOT_RUN or "coverage.py is not installed" not in out.getvalue():
        failures.append(f"[coverage.py missing] main_check exited {code}, not {CANNOT_RUN} "
                        "saying coverage.py is not installed")
    return failures


def self_test() -> int:
    failures = []
    with tempfile.TemporaryDirectory(prefix="gate-coverage-self-test-") as tmp, \
            mock.patch.dict(os.environ, {"GIT_CEILING_DIRECTORIES": tmp}):
        failures += repo_outcomes(Path(tmp))
    floor, overrides = load_floors(FLOORS + '"scripts/a.py" = { line = 100, branch = 90, why = '
                                   '"held higher" }\n', TRACKED)
    if (floor, overrides) != (Floor(75, 60), {"scripts/a.py": Floor(100, 90, "held higher")}):
        failures.append(f"the floors read back as {floor}, {overrides}")
    for name, text, says in FLOOR_REFUSALS:
        try:
            load_floors(text, TRACKED)
            failures.append(f"[{name}] accepted, not refused saying {says!r}")
        except FloorsError as e:
            if says not in str(e):
                failures.append(f"[{name}] refused saying {e}, not {says!r}")
    for name, got, held, says in VERDICTS:
        found = findings(TRACKED, got, Floor(75, 60), held)
        if says is None and found:
            failures.append(f"[{name}] reported {found}")
        if says is not None and not any(says in f for f in found):
            failures.append(f"[{name}] reported {found}, nothing saying {says!r}")
    with contextlib.redirect_stdout(io.StringIO()):
        failed = run_all(ROOT, [("passes", [sys.executable, "-c", "pass"]),
                                ("fails", [sys.executable, "-c", "raise SystemExit(3)"])])
    if [f.split(" ", 1)[0] for f in failed] != ["fails"] or "exited 3" not in failed[0]:
        failures.append(f"run_all reported {failed}, not the one command that failed")
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    cases = 1 + len(FLOOR_REFUSALS) + len(VERDICTS) + 1 + len(REPOS) + 1
    if failures:
        print(f"gate-coverage self-test FAILED: {len(failures)} of {cases} case(s)", file=sys.stderr)
        return 1
    print(f"gate-coverage self-test passed ({cases} cases: the floors read back, "
          f"{len(FLOOR_REFUSALS)} malformed floors refused, {len(VERDICTS)} verdicts, a failed "
          f"command reported, {len(REPOS)} repositories run end to end, and no run without "
          "coverage.py).")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:]:
        print("usage: gate-coverage.py [--self-test]", file=sys.stderr)
        sys.exit(CANNOT_RUN)
    sys.exit(main_check())
