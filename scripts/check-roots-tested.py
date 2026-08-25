#!/usr/bin/env python3
"""Every OpenTofu root carries a test suite.

WHY THIS EXISTS

The CI test job discovers suites with `git ls-files '**/tests/*.tftest.hcl'` and
runs what it finds. That is the right shape for running them and the wrong shape
for guaranteeing them: a root with no tests/ directory contributes nothing to the
glob, so it is not skipped with a message — it is never mentioned. The job goes
green having tested everything that asked to be tested.

Four roots sat that way, three of them minting IAM and two of those cross-account
credentials whose trust policies nothing asserted. None of it was visible from a
passing build, and the job's own anti-vacuity floor could not help: it fires when
NO suite is found anywhere, not when one root is missing.

Discovery is the correct mechanism for running tests and the wrong one for
asserting coverage, because discovery cannot see an absence. This asserts the
absence.

WHAT IT CHECKS

Every directory under components/, modules/ and fleet/ that is an OpenTofu ROOT —
it has a versions.tf, which is what distinguishes a root from a sub-module — has
at least one *.tftest.hcl under tests/.

A root that genuinely should not be tested is named in EXEMPT with the reason,
and that entry is asserted: naming a root that no longer exists fails the run,
because an exemption matching nothing exempts nothing today and covers whatever
takes that path next.

Exit 0 = every root is covered. Exit 1 = an untested root, or no roots found.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Roots deliberately without a suite, and why. Empty is the correct state.
EXEMPT: dict[str, str] = {}


def tracked(*globs: str) -> list[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", *globs],
        capture_output=True, text=True, check=True,
    ).stdout.split()


def main() -> int:
    # A root is a directory with a versions.tf. Sub-modules under modules/tenant/
    # have one too in this repo, so roots are restricted to the top level of each
    # tree — which is exactly what `tofu test` is run against.
    # Depth-filtered in Python, NOT by the pathspec: git's `*` matches across `/`,
    # so "components/*/*/versions.tf" also returns
    # components/aws/druid/modules/tenant/versions.tf. Those sub-modules have a
    # versions.tf but are called by their parent rather than run by `tofu test`,
    # and counting them as roots is the same granularity error this gate exists to
    # catch — a check whose enumeration is coarser or finer than its claim.
    roots = sorted({
        str(Path(p).parent)
        for p in tracked("**/versions.tf")
        if len(Path(p).parts) == 4
        and Path(p).parts[0] in ("components", "modules", "fleet")
    })

    if len(roots) < 20:
        print(
            f"FAIL: only {len(roots)} OpenTofu root(s) discovered (expected >= 20). "
            f"The scan could not see the tree; refusing to report a pass.",
            file=sys.stderr,
        )
        return 1

    suites = tracked("components/**/tests/*.tftest.hcl", "modules/**/tests/*.tftest.hcl",
                     "fleet/**/tests/*.tftest.hcl")
    tested = {str(Path(s).parent.parent) for s in suites}

    stale = sorted(set(EXEMPT) - set(roots))
    if stale:
        print(
            "EXEMPT entr(ies) naming a root that no longer exists:\n"
            + "".join(f"  - {r}\n" for r in stale)
            + "\nRemove the entry. An exemption describing nothing is a permission "
            "waiting for the next root to take that path.",
            file=sys.stderr,
        )
        return 1

    untested = [r for r in roots if r not in tested and r not in EXEMPT]
    if untested:
        print("OpenTofu root(s) with no test suite:\n", file=sys.stderr)
        for r in untested:
            print(f"  {r}", file=sys.stderr)
        print(
            "\nThe CI test job DISCOVERS suites, so a root with none is not skipped "
            "with a message — it is never mentioned, and the job goes green having "
            "tested everything that asked to be tested. Add "
            "<root>/tests/<name>.tftest.hcl, or name the root in EXEMPT here with "
            "the reason it needs none.",
            file=sys.stderr,
        )
        return 1

    print(
        f"✓ every OpenTofu root carries a test suite "
        f"({len(roots)} root(s), {len(suites)} suite(s), {len(EXEMPT)} exempt)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
