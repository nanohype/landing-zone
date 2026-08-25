#!/usr/bin/env python3
"""Every workflow job declares a timeout.

WHY THIS EXISTS

A job without `timeout-minutes` inherits GitHub's default of 360. That is not a
safety net, it is a six-hour bill for a job that has already stopped making
progress — a terragrunt run stuck on a provider call, an S3 lock nobody holds any
more, a network read with no deadline of its own.

The scheduled workflow is where it compounds: drift.yml runs every weekday, so a
hung run is still occupying a runner when the next one starts, and the failure
presents as a queue rather than as the hang it is.

This repo already applies the discipline to the code it ships — every wait loop
in scripts/e2e.sh is bounded against a deadline, and every kubectl call carries
--request-timeout. The workflows that run that code were the surface it had not
reached.

WHAT IT CHECKS

Every job with a `runs-on` carries a `timeout-minutes`. The VALUE is left to the
author: a budget sized to the work is a judgement about the work, and a gate that
guessed one would be overruled and then ignored. What cannot be left to judgement
is whether the bound exists at all.

Parsed with a real YAML parser rather than by regex, because a job key and a
`with:` key indent identically and a regex cannot reliably tell a nested mapping
from a top-level one.

Exit 0 = every job is bounded. Exit 1 = an unbounded job, or no workflow was read.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - environment without pyyaml
    print(
        "FAIL: PyYAML is not available, so this check cannot parse the workflows. "
        "It refuses to report a pass rather than skip: a check that silently does "
        "nothing when a dependency is missing is the failure it exists to prevent.",
        file=sys.stderr,
    )
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent


def workflows() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", ".github/workflows/*.yml", ".github/workflows/*.yaml"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [ROOT / p for p in out]


def main() -> int:
    files = workflows()

    # Anti-vacuity: with no workflows read there are no unbounded jobs to find,
    # and this would print a pass over an empty set.
    if not files:
        print(
            "FAIL: no workflow files found under .github/workflows/. The scan could "
            "not see them, so it has nothing to report on and refuses to pass.",
            file=sys.stderr,
        )
        return 1

    unbounded: list[str] = []
    checked = 0

    for path in files:
        doc = yaml.safe_load(path.read_text()) or {}
        jobs = doc.get("jobs") or {}
        for name, job in jobs.items():
            if not isinstance(job, dict):
                continue
            # A job that only calls a reusable workflow has no runs-on and takes
            # its budget from the workflow it calls.
            if "runs-on" not in job:
                continue
            checked += 1
            if "timeout-minutes" not in job:
                unbounded.append(f"  {path.relative_to(ROOT)}: {name}")

    if checked == 0:
        print(
            "FAIL: parsed the workflow files but found no job with a runs-on. The "
            "structure changed and this check is now blind.",
            file=sys.stderr,
        )
        return 1

    if unbounded:
        print("Workflow job(s) with no timeout-minutes:\n", file=sys.stderr)
        print("\n".join(unbounded), file=sys.stderr)
        print(
            "\nAn unbounded job inherits GitHub's 360-minute default, which is a "
            "six-hour bill for a job that stopped making progress — and on a "
            "scheduled workflow it stacks against the next run. Set a "
            "timeout-minutes sized to the work.",
            file=sys.stderr,
        )
        return 1

    print(f"✓ every workflow job declares a timeout ({checked} job(s) across {len(files)} workflow(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
