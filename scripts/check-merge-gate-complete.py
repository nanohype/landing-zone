#!/usr/bin/env python3
"""Every CI job is required by the merge gate.

WHY THIS EXISTS

Branch protection watches one required check, `merge gate`, which succeeds only
when everything in its `needs` list succeeded. A job missing from that list still
runs and still turns the PR's check list red — and merging is allowed anyway,
because the one check protection watches is green.

That is the worst failure mode a gate can have. The job exists, it runs, it
reports the violation, and it blocks nothing; a reviewer scanning for red sees
red and assumes it is enforced. Adding a gate is two edits — the job, and the
needs entry — and nothing about forgetting the second one looks like a mistake.

WHAT IT CHECKS

In `.github/workflows/ci.yml`, the set of job ids equals the merge gate's `needs`
list, in both directions:

  - a job not required by the merge gate is a check that cannot block a merge;
  - a `needs` entry naming no job makes GitHub fail the whole workflow, so this
    direction catches a rename before it reaches CI.

The merge gate requires itself only in the sense that it is excluded from its own
list; every other job must appear.

Exit 0 = every job is required. Exit 1 = an unrequired job, a dangling need, or
a workflow that could not be parsed.
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print(
        "FAIL: PyYAML is not installed, so this gate cannot read the workflow. "
        "Refusing to report a pass over a file it could not parse.",
        file=sys.stderr,
    )
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/ci.yml"
GATE_JOB = "merge-gate"

# Below this, a parse that produced almost nothing is likelier than a CI file
# that really has three jobs.
MIN_JOBS = 10


def main() -> int:
    if not WORKFLOW.exists():
        print(f"FAIL: {WORKFLOW.relative_to(ROOT)} does not exist.", file=sys.stderr)
        return 1

    doc = yaml.safe_load(WORKFLOW.read_text())
    jobs = set((doc or {}).get("jobs") or {})
    if len(jobs) < MIN_JOBS:
        print(
            f"FAIL: parsed only {len(jobs)} job(s) from ci.yml, below the "
            f"{MIN_JOBS} floor — the parse, not the workflow, is what changed. "
            f"Refusing to report a pass.",
            file=sys.stderr,
        )
        return 1
    if GATE_JOB not in jobs:
        print(
            f"FAIL: ci.yml has no `{GATE_JOB}` job. Branch protection watches "
            f"that one check; without it nothing is required.",
            file=sys.stderr,
        )
        return 1

    needs = doc["jobs"][GATE_JOB].get("needs") or []
    if isinstance(needs, str):
        needs = [needs]
    needs = set(needs)

    unrequired = sorted(jobs - needs - {GATE_JOB})
    dangling = sorted(needs - jobs)

    if unrequired or dangling:
        print("Merge gate does not require every job:\n", file=sys.stderr)
        for j in unrequired:
            print(f"  job `{j}` is not in {GATE_JOB}'s needs — it runs, it can go "
                  f"red, and it cannot block a merge", file=sys.stderr)
        for n in dangling:
            print(f"  {GATE_JOB} needs `{n}`, which is not a job — GitHub fails "
                  f"the workflow on this", file=sys.stderr)
        print(
            f"\nBranch protection watches `{GATE_JOB}` alone. A job outside its "
            f"needs list reports its violation onto a PR that is still mergeable, "
            f"which reads as enforced and is not.",
            file=sys.stderr,
        )
        return 1

    print(f"✓ the merge gate requires every CI job ({len(needs)} job(s) required)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
