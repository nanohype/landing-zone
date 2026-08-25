#!/usr/bin/env python3
"""The two fleet permissions-boundary ceilings grant the same actions.

WHY THIS EXISTS

`fleet-hub` and `fleet-vend` each author a permissions boundary that caps the
same roles: the cluster roles the fleet mints, and the agent-platform operator
role that runs on every cluster those roles build. A boundary is a ceiling, so
an action granted on a role's identity policy but missing from the ceiling is
silently clipped — the grant is accepted, appears in the console, and denies at
call time.

That produces a failure with no error at the point of the mistake. An operator
capability added to one ceiling and not the other works on a directly-applied
cluster and 403s on every vended one, which reads as a broken cluster rather
than a missing grant. The `aps:` reads and the `xray:` writes both landed this
way: each needed adding in two files, and each carried a comment saying so.

A comment saying "fix this in the same two places" is a memorial, not a control.
It records that the class exists and does nothing when the next action lands in
one file only. This gate is that sentence made enforceable.

WHAT IT CHECKS

The action sets of the two top-level ceiling statements are equal, except where
a divergence is waived on the granting line with

    "s3:*",  # ceiling-divergence-ok: <reason>

A waiver is per-action and needs a reason, so a deliberate asymmetry is stated
once and an accidental one has to be argued for rather than merely committed.

VIEW

Comments are blanked before actions are read: a commented-out action is not
granted, and an action named in prose is not a grant. The waiver is read from
the RAW line, because the waiver IS a comment — the two views answer different
questions and neither can serve both.

Exit 0 = the ceilings agree, or every divergence is waived with a reason.
Exit 1 = an unwaived divergence, a ceiling that could not be found, or a
ceiling so small the extraction plainly did not work.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from _hcl import blank_comments

ROOT = Path(__file__).resolve().parent.parent

# (file, Sid) of each ceiling. Named rather than discovered: there are exactly
# two, and a discovery rule broad enough to find them would also find the deny
# statements and the bucket policies that legitimately differ.
CEILINGS = [
    ("components/aws/fleet-hub/main.tf", "HubCeiling"),
    ("components/aws/fleet-vend/main.tf", "InfraProvisioningCeiling"),
]

# Below this an extraction failure is more likely than a real ceiling. Both
# ceilings grant ~30 actions; a handful means the block boundaries moved.
MIN_ACTIONS = 20

WAIVER = re.compile(r"#[ \t]*ceiling-divergence-ok:[ \t]*\S")
ACTION = re.compile(r'"([a-z0-9-]+:[A-Za-z0-9*]+)"')



def ceiling_actions(rel: str, sid: str) -> tuple[dict[str, int], str | None]:
    """Actions granted by one ceiling statement -> {action: line number}.

    Returns ({}, reason) when the statement could not be read, so an extraction
    failure is never indistinguishable from a ceiling that grants nothing.
    """
    path = ROOT / rel
    if not path.exists():
        return {}, f"{rel} does not exist"
    raw = path.read_text()
    code = blank_comments(raw)

    m = re.search(rf'Sid\s*=\s*"{re.escape(sid)}"', code)
    if not m:
        return {}, f"{rel}: no statement with Sid {sid}"
    start = code.find("Action", m.end())
    open_bracket = code.find("[", start)
    close = code.find("]", open_bracket)
    if start < 0 or open_bracket < 0 or close < 0:
        return {}, f"{rel}: Sid {sid} has no bracketed Action list"

    found: dict[str, int] = {}
    for a in ACTION.finditer(code[open_bracket:close]):
        line = code.count("\n", 0, open_bracket + a.start()) + 1
        found.setdefault(a.group(1), line)
    return found, None


def waived(rel: str, line: int) -> bool:
    """Is the grant on this line waived? Read from the RAW text — a waiver is a comment."""
    raw = (ROOT / rel).read_text().splitlines()
    return 0 < line <= len(raw) and bool(WAIVER.search(raw[line - 1]))


def main() -> int:
    sets: dict[str, dict[str, int]] = {}
    for rel, sid in CEILINGS:
        acts, why = ceiling_actions(rel, sid)
        if why:
            print(f"FAIL: {why}. Refusing to report a pass over a ceiling it could not read.", file=sys.stderr)
            return 1
        if len(acts) < MIN_ACTIONS:
            print(
                f"FAIL: {rel} Sid {sid} yielded only {len(acts)} action(s), "
                f"below the {MIN_ACTIONS} floor — the extraction, not the ceiling, "
                f"is what changed. Refusing to report a pass.",
                file=sys.stderr,
            )
            return 1
        sets[rel] = acts

    (a_rel, _), (b_rel, _) = CEILINGS
    a, b = sets[a_rel], sets[b_rel]

    problems: list[str] = []
    for owner, other, other_rel in ((a, b, b_rel), (b, a, a_rel)):
        owner_rel = a_rel if owner is a else b_rel
        for action, line in sorted(owner.items()):
            if action in other or waived(owner_rel, line):
                continue
            problems.append(
                f"  {owner_rel}:{line}: {action} — granted here, absent from {other_rel}"
            )

    if problems:
        print("Fleet ceiling divergence:\n", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        print(
            "\nBoth boundaries cap the same cluster and agent-platform operator "
            "roles. An action in one ceiling and not the other is granted on a "
            "directly-applied cluster and clipped on every vended one — an "
            "access denial at call time with nothing wrong at the point of the "
            "grant. Add it to both, or waive it on the granting line with "
            "`# ceiling-divergence-ok: <reason>`.",
            file=sys.stderr,
        )
        return 1

    shared = len(set(a) & set(b))
    waivers = sum(
        1
        for owner, other in ((a, b), (b, a))
        for action in owner
        if action not in other
    )
    print(
        f"✓ the two fleet ceilings grant the same actions "
        f"({shared} shared across 2 ceiling(s); {waivers} waived divergence(s))"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
