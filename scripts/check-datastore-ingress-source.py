#!/usr/bin/env python3
"""A datastore's ingress must admit the NODE security group, never the cluster SG.

`cluster_security_group_id` is attached to the EKS CONTROL PLANE's ENIs. No
packet a pod sends carries it. A datastore whose ingress rule names it therefore
admits nobody — the rule is syntactically valid, applies cleanly, and silently
accepts no traffic. Nothing fails. The tenant's workload just hangs on connect
until something upstream times out, and the timeout points at the application.

The group that matters is `node_security_group_id`: every packet leaving a pod
for a datastore exits the node's ENI and carries the node SG. That reasoning is
written out at `components/aws/tenant-substrate/variables.tf:27-36` and
`components/aws/cluster/outputs.tf:21-27`.

This gate exists because the fix reached one component and not its siblings.
`tenant-substrate` moved to `node_sg_id`; `druid` and `pipeline` kept
`cluster_sg_id` on three datastores — an Aurora cluster and two MSK clusters —
and the commit that made the change was titled "Admit the node security group to
EVERY tenant datastore". A title is not a gate.

Exit 0 = clean. Exit 1 = a datastore admits the wrong group, or the scan was blind.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Attributes whose value names the SOURCE of an ingress rule.
INGRESS_SOURCE_ATTRS = ("source_security_group_id", "security_groups")

# An inline waiver must name why the control-plane SG is genuinely the source:
#   source_security_group_id = var.cluster_sg_id # cluster-sg-ingress-ok: <reason>
WAIVER = re.compile(r"#\s*cluster-sg-ingress-ok:\s*\S")

ASSIGN = re.compile(
    r"^\s*(?P<attr>" + "|".join(INGRESS_SOURCE_ATTRS) + r")\s*=\s*(?P<rhs>.+?)\s*$"
)
CLUSTER_SG = re.compile(r"\bvar\.cluster_sg_id\b")


def tracked_tf_files() -> list[Path]:
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


def violations(path: Path) -> list[tuple[int, str]]:
    found = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        m = ASSIGN.match(line)
        if not m:
            continue
        if not CLUSTER_SG.search(m.group("rhs")):
            continue
        if WAIVER.search(line):
            continue
        found.append((n, line.strip()))
    return found


def main() -> int:
    files = tracked_tf_files()

    # Anti-vacuity guard: a blind scan must fail, not report a reassuring zero.
    if len(files) < 50:
        print(
            f"FAIL: only {len(files)} .tf files found under components/modules/fleet "
            f"(expected >= 50). The scan could not see the tree; refusing to report "
            f"a pass.",
            file=sys.stderr,
        )
        return 1

    bad = []
    for f in files:
        for n, text in violations(f):
            bad.append((f.relative_to(ROOT), n, text))

    if bad:
        print("Datastore ingress admits the CLUSTER security group:\n", file=sys.stderr)
        for rel, n, text in bad:
            print(f"  {rel}:{n}: {text}", file=sys.stderr)
        print(
            "\ncluster_sg_id is attached to the EKS control plane's ENIs, so no packet a "
            "pod sends carries it. This rule applies cleanly and admits nobody — the "
            "workload hangs on connect and the timeout blames the application.\n"
            "Use var.node_sg_id. If the control-plane SG is genuinely the intended "
            "source, waive it inline:  # cluster-sg-ingress-ok: <why>",
            file=sys.stderr,
        )
        return 1

    print(f"✓ every datastore ingress sources the node SG ({len(files)} .tf files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
