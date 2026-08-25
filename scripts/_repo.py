"""Shared precondition: the gate is looking at this repository.

Not a gate: the filename is outside the `check-*` glob that `task gates`, CI and
the positive-control floor discover, so this file is imported and never run.

WHY THIS EXISTS

A gate that reports on a tree it cannot see reports a pass. Guarding that with
"at least one file matched" is not enough, because the count answers a different
question: it says the PATTERN matched something, not that the REPOSITORY is
there. A tree holding nothing but the gate scripts satisfies "at least one shell
script" using the gates' own files, and every shell-reading gate then passes
over a repository that is absent.

Printing the denominator does not close this either. `0 unwrapped call(s)
checked across 2 script(s)` is an accurate report of a vacuous scan, and it was
printed immediately before an exit 0.

WHAT IT CHECKS

That the tracked set contains something other than `scripts/`. It is exact
rather than a threshold: a repository is present or it is not, and a number
chosen today drifts as the tree grows.
"""

from __future__ import annotations

import subprocess
from pathlib import Path


def repo_is_visible(root: Path) -> tuple[bool, str]:
    """(True, "") when the tracked tree is more than the gate scripts.

    Returns the reason rather than raising, so a caller reports it in its own
    voice — a gate's refusal should read like that gate, not like a library.
    """
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return False, (
            "`git ls-files` failed, so the tracked set could not be read. This "
            "gate reads the repository through git; without it there is nothing "
            "to check rather than nothing to report."
        )
    tracked = [p for p in proc.stdout.split("\n") if p]
    if not tracked:
        return False, "the tracked set is empty — this is not a checkout of the repository."
    outside = [p for p in tracked if not p.startswith("scripts/")]
    if not outside:
        return False, (
            f"every one of the {len(tracked)} tracked file(s) is under scripts/, "
            f"so the only thing here is the gates themselves. A scan of this tree "
            f"reports on nothing and would exit 0 saying so."
        )
    return True, ""
