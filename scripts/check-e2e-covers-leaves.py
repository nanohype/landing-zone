#!/usr/bin/env python3
"""Every live leaf is either exercised by the e2e run or explicitly exempt.

WHY THIS EXISTS

`scripts/e2e.sh` provisions a real substrate, deploys a tenant through it, tears
everything down, and then asserts nothing billable survived. That last assertion
is the reason the script is trusted, and it can only see what the run created.

`tenant-substrate` — the component that provisions every stateful store a tenant
declares: Aurora, ElastiCache, DynamoDB, S3, SQS, MSK — was in neither the apply
list nor the destroy loop. So the zero-billable check could not have caught a
leaked Aurora cluster even if one had been standing, and nothing said so. The
run reported PASSED over a component it never touched.

Nothing could catch that. The five existing guard scripts all inspect
component-internal properties (teardown gates, schema readers, account-local
dependencies, mock and smoke outputs); none reads e2e.sh, and none compares its
component list against the set of leaves that actually exist.

WHAT THIS ASSERTS

Every directory under the e2e environment's live path is either

  1. named in e2e.sh's apply sequence AND its destroy loop, or
  2. listed in EXEMPT below with a reason.

Same shape as check-teardown-gates.py's own EXEMPT table, and for the same
reason: an exemption a human wrote down is a decision, and a component silently
missing from a list is an accident that reads identically.

    scripts/check-e2e-covers-leaves.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
E2E = ROOT / "scripts" / "e2e.sh"
LEAVES = ROOT / "live" / "aws" / "workload-development" / "us-west-2" / "development"

# A leaf the e2e run deliberately does not exercise, and why. An entry here is a
# decision; a leaf missing from both this table and e2e.sh is an accident.
EXEMPT: dict[str, str] = {
    "cluster-addons": "ArgoCD installs the addon fleet from eks-gitops once cluster-bootstrap "
    "runs; the run exercises that path through the operator install rather than by applying "
    "this leaf directly.",
    "observability": "Cluster-level telemetry wiring. Adds no billable resource the teardown "
    "check cannot already see, and its backends (AMP/Grafana) are account-scoped rather than "
    "created by the run.",
    "druid": "A workload component with no tenant in the e2e path. Applying it would provision "
    "a cluster the run has nothing to point at.",
    "pipeline": "As druid — a workload component the e2e tenant does not use.",
    "governance": "As druid — a workload component the e2e tenant does not use.",
    "model-import": "Bedrock Custom Model Import. Importing a model costs real money and takes "
    "tens of minutes; the run proves the substrate, not the model catalogue.",
    "backup": "Account-scoped backup plans and vaults, shared across environments. Destroying "
    "them at teardown would remove recovery points belonging to resources this run did not "
    "create — the one thing the run must never do.",
    "break-glass": "Deliberately unappliable: the leaves pass an empty principal list and the "
    "component refuses it. Nothing to apply.",
    "cost": "Account-scoped cost pipeline, shared. Same reason as backup.",
    "dns": "Account-scoped hosted zones, shared across environments and outliving any run.",
    "private-dns": "As dns — shared, and outlives the run.",
    "github-oidc": "Account-scoped CI trust. Destroying it at teardown would break the CI "
    "identity of the very workflow running the e2e.",
    "service-quotas": "Quota increase requests are account-scoped, asynchronous, and not "
    "reversible by a destroy.",
    "managed-monitoring": "Hub-side Amazon Managed Grafana. Runs on the fleet hub, not in a "
    "workload environment.",
}

APPLY_RE = re.compile(r'tg\s+([a-z0-9-]+)\s+apply')
DESTROY_RE = re.compile(r'for\s+c\s+in\s+([a-z0-9\- ]+);\s*do\s*\n\s*log\s+"destroy')


def e2e_applied() -> set[str]:
    text = E2E.read_text(encoding="utf-8")
    return set(APPLY_RE.findall(text))


def e2e_destroyed() -> set[str]:
    text = E2E.read_text(encoding="utf-8")
    m = DESTROY_RE.search(text)
    if not m:
        sys.exit(
            "FAIL  could not find e2e.sh's destroy loop — this check cannot verify teardown "
            "coverage and refuses to pass instead of guessing"
        )
    return set(m.group(1).split())


def leaves() -> set[str]:
    return {p.name for p in LEAVES.iterdir() if p.is_dir() and not p.name.startswith(".")}


def main() -> int:
    if not E2E.is_file():
        print(f"FAIL  {E2E.relative_to(ROOT)} is missing — the subject of this check")
        return 1

    found = leaves()
    if not found:
        print("FAIL  found no live leaves — this check would pass vacuously")
        return 1

    applied, destroyed = e2e_applied(), e2e_destroyed()
    if not applied or not destroyed:
        print("FAIL  parsed no apply or destroy entries from e2e.sh — this check would pass vacuously")
        return 1

    failures: list[str] = []

    for leaf in sorted(found):
        if leaf in EXEMPT:
            continue
        if leaf not in applied:
            failures.append(
                f"{leaf}: exists as a live leaf but e2e.sh never applies it.\n"
                "      Either add it to the apply sequence, or add it to EXEMPT with the reason.\n"
                "      A component the run does not create is one the zero-billable check at\n"
                "      teardown cannot see — it reports clean over a resource class it never looked at."
            )
        elif leaf not in destroyed:
            failures.append(
                f"{leaf}: e2e.sh applies it and never destroys it.\n"
                "      This is the worse half: the run creates billable resources and the teardown\n"
                "      walks past them, then reports PASSED."
            )

    # An exemption for a leaf that no longer exists is stale, and a stale table is
    # how the next missing component gets excused by accident.
    for name in sorted(EXEMPT):
        if name not in found:
            failures.append(
                f"{name}: listed in EXEMPT but is not a live leaf. Remove the entry — a table "
                "that has drifted from the tree stops describing it."
            )

    if failures:
        print(f"FAIL  {len(failures)} e2e coverage problem(s):\n")
        for f in failures:
            print(f"  - {f}\n")
        return 1

    covered = sorted(found - set(EXEMPT))
    print(
        f"✓ {len(found)} live leaves: {len(covered)} applied and destroyed by e2e.sh "
        f"({', '.join(covered)}), {len(EXEMPT)} exempt with a stated reason"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
