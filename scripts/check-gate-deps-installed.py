#!/usr/bin/env python3
"""Every CI job that runs a gate installs what that gate imports.

WHY THIS EXISTS

A gate that imports a third-party module and fails closed when it is absent is
behaving correctly — it refuses to report a pass over a file it could not parse.
But that refusal is indistinguishable, to the job around it, from the gate
finding a violation. The build goes red pointing at the tree when the actual
fault is a missing dependency in the workflow.

That is what it looks like in practice: two gates parse workflow YAML, the
positive-control job runs EVERY gate as a subprocess, and it did not install
PyYAML. The control job failed with "does not pass on the unmutated tree" —
true, and about the runner rather than the repo.

Adding a gate is two edits: the gate, and the install line in every job that
runs it. The second is easy to miss precisely because the gate works on a
developer machine where the module happens to be present.

WHAT IT CHECKS

For every `scripts/check-*.py`, the set of third-party imports. For every job in
ci.yml, which gates it runs — including the control job, which runs all of them.
Then: a job running a gate must install that gate's imports.

Third-party is decided by import machinery rather than a hand-kept allowlist, so
a gate reaching for a new module is covered without editing this file.

Exit 0 = every job installs what it needs. Exit 1 = a gate whose module no job
installs, or a scan that could not see the tree.
"""

from __future__ import annotations

import ast
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/ci.yml"

# A gate that runs every other gate needs every other gate's dependencies.
RUNS_EVERY_GATE = "check-gates-detect.py"

# Below this the scan found almost nothing, which is likelier than a repo with
# three gates.
MIN_GATES = 10


def third_party(module: str) -> bool:
    """True when the module is not part of the standard library.

    Decided by asking import machinery where the module lives, not by a list
    here — a list would need editing every time a gate reaches for something
    new, which is the same maintenance failure this gate exists to catch.
    """
    if module in sys.builtin_module_names:
        return False
    if (ROOT / "scripts" / f"{module}.py").exists():
        return False
    try:
        spec = importlib.util.find_spec(module)
    except (ImportError, ValueError):
        return True
    if spec is None or not spec.origin:
        return False
    return "site-packages" in spec.origin or "dist-packages" in spec.origin


def distributions_for(module: str) -> set[str]:
    """Package name(s) that provide this import name.

    An import name is not a package name — `import yaml` comes from `pyyaml`,
    and a matcher that compares the two strings directly reports a job as
    missing a dependency it installs. importlib.metadata answers this
    authoritatively from installed metadata rather than from a list kept here,
    which would need editing for every new module and is the maintenance failure
    this gate exists to catch.

    packages_distributions() landed in Python 3.10. Where it is absent, or where
    the module is not installed locally at all, fall back to accepting a package
    whose normalised name CONTAINS the import name — `pyyaml` for `yaml`. That
    is looser than the metadata answer and is only ever reached when the precise
    answer is unavailable.
    """
    names = {module}
    try:
        from importlib.metadata import packages_distributions
    except ImportError:
        return names
    try:
        for dist in packages_distributions().get(module, []):
            names.add(dist)
    except Exception:
        pass
    return names


def imports_of(path: Path) -> set[str]:
    mods: set[str] = set()
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.Import):
            mods.update(a.name.split(".")[0] for a in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            mods.add(node.module.split(".")[0])
    return {m for m in mods if third_party(m)}


def main() -> int:
    gates = sorted(
        p for p in ROOT.joinpath("scripts").glob("check-*.py")
        if subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "--error-unmatch", str(p.relative_to(ROOT))],
            capture_output=True,
        ).returncode == 0
    )
    if len(gates) < MIN_GATES:
        print(
            f"FAIL: found only {len(gates)} tracked gate(s), below the {MIN_GATES} "
            f"floor — the scan could not see the tree. Refusing to report a pass.",
            file=sys.stderr,
        )
        return 1

    needs = {g.name: imports_of(g) for g in gates}

    if not WORKFLOW.exists():
        print(f"FAIL: {WORKFLOW.relative_to(ROOT)} does not exist.", file=sys.stderr)
        return 1
    text = WORKFLOW.read_text()

    # Split into jobs by top-level indentation rather than parsing YAML: this
    # gate must not itself depend on a third-party module to check whether
    # third-party modules are installed.
    job_starts = [(m.start(), m.group(1)) for m in re.finditer(r"^  ([a-z0-9][a-z0-9-]*):$", text, re.M)]
    if not job_starts:
        print("FAIL: no jobs parsed from ci.yml. Refusing to report a pass.", file=sys.stderr)
        return 1

    problems: list[str] = []
    checked = 0
    for i, (start, job) in enumerate(job_starts):
        end = job_starts[i + 1][0] if i + 1 < len(job_starts) else len(text)
        body = text[start:end]

        run_here = {g for g in needs if g in body}
        if RUNS_EVERY_GATE in run_here:
            run_here |= set(needs)

        required: set[str] = set()
        for g in run_here:
            required |= needs[g]
        if not required:
            continue
        checked += 1

        for module in sorted(required):
            candidates = distributions_for(module)
            installed = any(
                re.search(rf"pip install[^\n]*\b{re.escape(c)}\b", body, re.I)
                for c in candidates
            ) or re.search(
                rf"pip install[^\n]*[A-Za-z0-9_-]*{re.escape(module)}[A-Za-z0-9_-]*", body, re.I
            )
            if not installed:
                culprits = sorted(g for g in run_here if module in needs[g])
                line = text.count("\n", 0, start) + 1
                problems.append(
                    f"  .github/workflows/ci.yml:{line}: job `{job}` runs "
                    f"{', '.join(culprits)} which import(s) `{module}`, and installs no such package"
                )

    if problems:
        print("CI job(s) missing a gate's dependency:\n", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        print(
            "\nA gate that fails closed on a missing module is correct, and the "
            "job around it cannot tell that refusal apart from a real finding — "
            "so the build goes red pointing at the tree. Add a pinned "
            "`pip install <module>==<version>` step to the job.",
            file=sys.stderr,
        )
        return 1

    total = sum(len(v) for v in needs.values())
    print(
        f"✓ every CI job installs what its gates import "
        f"({total} third-party import(s) across {len(gates)} gate(s); "
        f"{checked} job(s) needed one)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
