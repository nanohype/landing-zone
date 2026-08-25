#!/usr/bin/env python3
"""No file may name an AWS region the live tree does not deploy into.

The region a reader believes this repo targets comes from prose and examples,
not from the tree: `task plan REGION=...` in a README, a path in a skill, an ARN
in a runbook, a mock in a test fixture. When those disagree with `live/aws/`, the
tree is right and every copied command lands on a directory that does not exist.

The disagreement is also asymmetric in a way that hides it. Moving the live tree
to a new region is a mechanical rename that CI notices immediately; moving the
prose is a hand edit across dozens of files that nothing checks, so the prose is
what survives a region change and the drift only surfaces when someone runs a
documented command.

The rule: the set of regions named anywhere in the repo must be a subset of the
regions the live tree actually contains. `live/aws/<account>/<region>/` is the
source of truth — this gate never hard-codes a region, so retargeting the estate
is still a matter of moving the trees, and the prose is then required to follow.

A file that must name a foreign region (documenting a cross-region constraint,
say) waives it with a comment naming the region and the reason. The waiver covers
that region for the whole file, because the sentence explaining a region rarely
sits on the same line as the region:

    # region-ok: <region> is the replica target the DR runbook restores into

A waiver whose region appears nowhere else in the file is itself reported: it
exempts nothing today and pre-approves that region for whatever is added next.

Exit 0 = clean. Exit 1 = a foreign region, or the scan could not see the tree.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Every public AWS region shape: <area>-<direction>[-<qualifier>]-<n>. Broad on
# purpose — a gate that only knew the regions it was written against would go
# blind to the next one AWS ships, which is the same vacuous-pass failure the
# anti-vacuity guard below exists for.
REGION = re.compile(
    r"\b(?:af|ap|ca|cn|eu|il|me|sa|us|us-gov)-"
    r"(?:north|south|east|west|central|northeast|northwest|southeast|southwest)"
    r"-\d\b"
)

# The availability-zone id form derived from a region (us-east-1 -> use1-az1).
# It drifts independently of the region string and reads as correct to everyone
# except the AZ-id lookup that resolves it.
AZ_ID = re.compile(r"\b([a-z]{2,4}\d)-az\d\b")

WAIVER = re.compile(r"#\s*region-ok:\s*\S")

# Generated or vendored text is not this repo's prose. Provider lock files carry
# no regions; live/ is the source of truth this gate reads rather than checks.
SKIP_PREFIXES = ("live/",)
SKIP_NAMES = (".terraform.lock.hcl",)

SCANNED_SUFFIXES = (".tf", ".hcl", ".md", ".sh", ".py", ".yml", ".yaml", ".json")


def tracked_files() -> list[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()


def live_regions(tracked: list[str]) -> set[str]:
    """The regions the live tree deploys into: live/aws/<account>/<region>/..."""
    found = set()
    for rel in tracked:
        parts = Path(rel).parts
        if len(parts) >= 4 and parts[0] == "live" and parts[1] == "aws":
            if REGION.fullmatch(parts[3]):
                found.add(parts[3])
    return found


# AWS abbreviates the compass segment of a region into an AZ id: the area code
# survives whole, each following segment collapses to its initials, and the
# number is kept. us-east-1 -> use1, ap-southeast-2 -> apse2, us-gov-west-1 ->
# usgw1. The compound directions are two letters, not one, which is the part a
# naive first-letter rule gets wrong.
#
# region-ok: ap-southeast-2 and us-gov-west-1 are worked examples of the
# abbreviation rule, chosen because they exercise the compound direction and the
# three-segment area that a one-letter rule gets wrong. This file has to name
# regions it does not deploy into to describe the transform at all.
DIRECTION_ABBREV = {
    "north": "n",
    "south": "s",
    "east": "e",
    "west": "w",
    "central": "c",
    "northeast": "ne",
    "northwest": "nw",
    "southeast": "se",
    "southwest": "sw",
}


def az_prefixes(regions: set[str]) -> set[str]:
    """AZ-id prefixes for a region set: us-east-1 -> use1, ap-southeast-2 -> apse2."""
    out = set()
    for r in regions:
        head, _, num = r.rpartition("-")
        area, *rest = head.split("-")
        out.add(area + "".join(DIRECTION_ABBREV.get(s, s[0]) for s in rest) + num)
    return out


def scan(rel: str, allowed: set[str], allowed_az: set[str]) -> list[tuple[int, str]]:
    path = ROOT / rel
    try:
        text = path.read_text()
    except (UnicodeDecodeError, OSError):
        return []  # binary or unreadable; carries no prose

    lines = text.splitlines()

    # A waiver names the token it waives and covers the whole file. Scoping it to
    # its own line would be the obvious rule and the wrong one: the region being
    # explained is usually a line or two above the sentence explaining it, so a
    # line-scoped waiver silently fails to cover the thing it was written for and
    # the author moves the comment around until the gate goes quiet.
    waived = set()
    for line in lines:
        if WAIVER.search(line):
            waived.update(m.group(0) for m in REGION.finditer(line))
            waived.update(m.group(0) for m in AZ_ID.finditer(line))

    # A waiver naming a region that no longer appears in this file is dead, and it
    # is dead in the permissive direction: it silently pre-approves that region for
    # whatever gets added here next. Report it rather than let it sit.
    dead_waivers = set()
    if waived:
        present = set()
        for line in lines:
            if WAIVER.search(line):
                continue
            present.update(m.group(0) for m in REGION.finditer(line))
            present.update(m.group(0) for m in AZ_ID.finditer(line))
        dead_waivers = {w for w in waived if w not in present and w not in allowed}

    bad = []
    for n, line in enumerate(lines, 1):
        for m in REGION.finditer(line):
            if m.group(0) not in allowed and m.group(0) not in waived:
                bad.append((n, m.group(0)))
        for m in AZ_ID.finditer(line):
            if m.group(1) not in allowed_az and m.group(0) not in waived:
                bad.append((n, m.group(0)))
    return bad, dead_waivers


def main() -> int:
    tracked = tracked_files()
    allowed = live_regions(tracked)

    # Anti-vacuity guard, in both directions. With no regions resolved every
    # region in the repo would be foreign and the gate would fire on everything;
    # with no files scanned it would pass over nothing. Either state means the
    # scan could not see the tree, and both must fail loudly rather than report.
    if not allowed:
        print(
            "FAIL: no region directories found under live/aws/<account>/<region>/. "
            "The scan could not see the live tree; refusing to report a pass or a "
            "storm of false positives.",
            file=sys.stderr,
        )
        return 1

    targets = [
        rel
        for rel in tracked
        if rel.endswith(SCANNED_SUFFIXES)
        and not rel.startswith(SKIP_PREFIXES)
        and Path(rel).name not in SKIP_NAMES
    ]
    if len(targets) < 100:
        print(
            f"FAIL: only {len(targets)} scannable files found (expected >= 100). "
            f"The scan could not see the tree; refusing to report a pass.",
            file=sys.stderr,
        )
        return 1

    allowed_az = az_prefixes(allowed)
    bad: list[tuple[str, int, str]] = []
    dead: list[str] = []
    for rel in targets:
        hits, dead_waivers = scan(rel, allowed, allowed_az)
        for n, token in hits:
            bad.append((rel, n, token))
        dead.extend(f"  {rel}: waives {w}, which the file no longer names" for w in sorted(dead_waivers))

    if dead:
        print(
            "Dead region waiver(s):\n" + "\n".join(dead) + "\n\n"
            "A waiver naming a region the file no longer contains exempts nothing "
            "today and pre-approves that region for whatever is added here next. "
            "Remove it.",
            file=sys.stderr,
        )
        return 1

    if bad:
        listed = ", ".join(sorted(allowed))
        print(
            f"Region(s) named that the live tree does not deploy into "
            f"(live/aws/ contains: {listed}):\n",
            file=sys.stderr,
        )
        for rel, n, token in bad:
            print(f"  {rel}:{n}: {token}", file=sys.stderr)
        print(
            "\nA documented command naming a region with no directory under it "
            "fails for whoever copies it. Retarget the prose to the region the "
            "tree deploys into, or — if the file must name a foreign region to "
            "describe a cross-region constraint — waive it inline with a reason:\n"
            "  # region-ok: <why this region and not the deploy region>",
            file=sys.stderr,
        )
        return 1

    print(
        f"✓ every region named resolves to a live tree "
        f"({len(targets)} files scanned, {len(allowed)} region(s) deployed)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
