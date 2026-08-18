#!/usr/bin/env python3
"""No component may hard-code a MINOR version of a managed engine.

A managed-engine version is not a stable identifier. AWS withdraws minor
versions, and which minors a region offers differs by region. A component
pinned to `engine_version = "16.6"` therefore encodes a bet on what AWS still
offers in every region an adopter deploys into — and loses that bet silently,
at apply time, after the expensive resources underneath it already exist.

That is not hypothetical. `components/aws/druid/modules/tenant/aurora.tf` was
pinned to "16.6" and failed every apply with `Cannot find version 16.6 for
aurora-postgresql` once AWS withdrew it, after the VPC and the EKS cluster were
already built and billing. The same reasoning is written out at
`components/aws/tenant-substrate/variables.tf:79-84`, which is where the fix
landed first; this gate exists because it landed in only one of the two places
that needed it, and nothing noticed for eight days.

The rule: a version LITERAL assigned to a managed-engine version attribute must
name a major only. `"16"` passes. `"16.6"` fails. Anything non-literal --
`var.x`, `each.value.relational.engine_version`, `optional(string, "16")` -- is
a value the caller supplies, and a tenant deliberately holding itself on one
minor is the documented escape hatch, not this gate's business.

Exit 0 = clean. Exit 1 = a minor pin, or the scan could not see the tree.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Attributes whose value names a managed-engine version AWS can retire.
ATTRS = (
    "engine_version",
    "kafka_version",
    "elasticsearch_version",
)

# A component may hold a minor pin only with an inline waiver naming why:
#   engine_version = "16.6" # minor-pin-ok: <reason>
WAIVER = re.compile(r"#\s*minor-pin-ok:\s*\S")

ASSIGN = re.compile(
    r"^\s*(?P<attr>" + "|".join(ATTRS) + r")\s*=\s*(?P<rhs>.+?)\s*$"
)
# A bare quoted literal on the right-hand side, e.g.  = "16.6"
LITERAL = re.compile(r'^"(?P<value>[^"]*)"')
# Same, but inside an optional() default:  = optional(string, "16.6")
OPTIONAL_DEFAULT = re.compile(r'^optional\(\s*string\s*,\s*"(?P<value>[^"]*)"')

MINOR = re.compile(r"^\d+\.\d")


def tracked_tf_files() -> list[Path]:
    """Every tracked .tf under the module trees. Tests are excluded: a test
    asserting behaviour AT a specific minor is asserting, not deploying."""
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "*.tf"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    keep = []
    for rel in out:
        p = Path(rel)
        if p.parts[0] not in ("components", "modules", "fleet"):
            continue
        if "tests" in p.parts:
            continue
        keep.append(ROOT / p)
    return keep


def violations(path: Path) -> list[tuple[int, str, str]]:
    found = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        m = ASSIGN.match(line)
        if not m:
            continue
        rhs = m.group("rhs")
        lit = LITERAL.match(rhs) or OPTIONAL_DEFAULT.match(rhs)
        if not lit:
            continue  # var / each.value / expression -- caller's choice
        value = lit.group("value")
        if not MINOR.match(value):
            continue  # major-only, or a non-numeric scheme
        if WAIVER.search(line):
            continue
        found.append((n, m.group("attr"), value))
    return found


def main() -> int:
    files = tracked_tf_files()

    # Anti-vacuity guard. A gate whose healthy output is indistinguishable from
    # its blind output is the failure it exists to catch: if the glob, the cwd
    # or `git ls-files` ever stops matching, this must fail rather than print a
    # reassuring zero.
    if len(files) < 50:
        print(
            f"FAIL: only {len(files)} .tf files found under components/modules/fleet "
            f"(expected >= 50). The scan could not see the tree; refusing to "
            f"report a pass.",
            file=sys.stderr,
        )
        return 1

    bad = []
    for f in files:
        for n, attr, value in violations(f):
            bad.append((f.relative_to(ROOT), n, attr, value))

    if bad:
        print("Minor-version pin(s) on a managed engine:\n", file=sys.stderr)
        for rel, n, attr, value in bad:
            major = value.split(".")[0]
            print(f"  {rel}:{n}: {attr} = \"{value}\"  -> use \"{major}\"", file=sys.stderr)
        print(
            "\nAWS retires minor versions and regional availability differs, so a "
            "minor pin fails at apply time — after the resources underneath it "
            "exist. Pin the major and let the service resolve the newest minor.\n"
            "If a specific minor is genuinely required, waive it inline with a "
            "reason:  # minor-pin-ok: <why>",
            file=sys.stderr,
        )
        return 1

    print(f"✓ no minor-version engine pins ({len(files)} .tf files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
