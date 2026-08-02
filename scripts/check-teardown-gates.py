#!/usr/bin/env python3
"""check-teardown-gates.py — every teardown gate on a component moves on one lever.

A component that can be applied and cannot be destroyed leaves a deployment you can
validate exactly once. So `force_destroy_buckets` exists: the operator's declaration
that this substrate is disposable, honoured unconditionally in development and opt-in
elsewhere. The rule this enforces is that the declaration reaches EVERY gate, not most
of them.

Why a partial gate is worse than no gate. AWS spreads the protections across unrelated
resources — force_destroy on a bucket, skip_final_snapshot and deletion_protection on a
database, deletion_protection_enabled on a table — and nothing in the dependency graph
joins them, so the destroy walks them concurrently. Gate the buckets but not the
database and a permitted teardown empties the buckets, fails on DeleteDBCluster, and
halts the reverse sweep above cluster and network: the data is gone, the database is
still standing, and the EKS control plane, VPC and NAT gateways are all still billing.
That is strictly worse than refusing the teardown outright, and it is what this repo
shipped until every deletion_protection was wired to the lever.

Why this is a static check and not a `tofu test`. The gate values live on resources
inside child modules — `module.tenant` -> `module.aurora` (the vendored rds-aurora
module) -> `aws_rds_cluster`. A test `assert` can reach the root module's outputs and
resources, not a grandchild's attributes, so asserting the value means re-stating the
expression in an output and comparing it to itself. That passes while the resource is
wrong, which is the exact failure class this repo keeps finding: an artifact that is
valid and insufficient. Reading the resource bodies is the only assertion that binds.

So the check reads polarity, not presence. `deletion_protection = local.allow_teardown`
mentions the lever and is inverted — armed exactly when teardown is permitted. Requiring
the permissive branch to be spelled out catches that.

Two rules:

  1. In a module that declares `force_destroy_buckets`, every teardown-gate attribute
     must resolve permissively when the lever is set.
  2. A protectable resource in a module that does NOT declare the lever must be named
     in EXEMPT below, with a reason. Teardown posture is then a declared decision
     rather than an omission, and a new unguarded bucket cannot land silently.
"""

import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

# Attributes that gate a destroy, and what each must look like when the lever is set.
# "permissive" is the branch value required on the lever-true side.
GATES = {
    "force_destroy": "true",
    "skip_final_snapshot": "true",
    "final_snapshot_identifier": "null",
    "deletion_protection": "false",
    "deletion_protection_enabled": "false",
}

# Resource types and vendored modules that carry a teardown gate. Used by rule 2 to
# notice a protectable resource in a module with no lever at all.
PROTECTABLE_RESOURCES = (
    "aws_s3_bucket",
    "aws_rds_cluster",
    "aws_db_instance",
    "aws_dynamodb_table",
)
PROTECTABLE_MODULE_SOURCES = ("s3-bucket", "rds-aurora")

# Teardown posture declared deliberately, outside the lever idiom. Each entry is a
# module directory and why it is not disposable. Keep the reason specific — this table
# is the answer to "can this component be torn down?", and a vague entry is how a wedge
# gets re-derived by the next reader.
EXEMPT = {
    "components/aws/cost": (
        "The CUR bucket gates force_destroy on the environment inline. Account-level "
        "billing data has no per-cluster lifecycle, so there is no substrate for a "
        "force_destroy_buckets lever to be about."
    ),
    "components/aws/fleet-hub": (
        "Crown jewels. The vend state bucket and its CMK carry prevent_destroy: they "
        "outlive every spoke they vend, so a deliberate teardown removes the guard "
        "first, by hand and on purpose."
    ),
    "components/aws/portal-hub": (
        "Crown jewels, same posture as fleet-hub — the portal's workspace state "
        "bucket and CMK carry prevent_destroy and outlive the clusters they describe."
    ),
    "components/aws/org-cost": (
        "The CUR 2.0 export bucket is `org-<account>-cur-export` in the management "
        "account — one per organization, holding the billing history every cost "
        "report reads back over months. It is not vended with a cluster and no "
        "cluster teardown should reach it."
    ),
    "components/aws/org-compliance": (
        "The CloudTrail and Config sinks are account-singleton audit evidence in the "
        "management account. They are not vended with a cluster and must survive one; "
        "destroying them is an organization decision, not a teardown step."
    ),
}


def tracked_tf_files():
    out = subprocess.run(
        ["git", "ls-files", "components/**/*.tf", "modules/**/*.tf"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    return [Path(p) for p in out]


def strip_variable_blocks(lines):
    """Yield (lineno, text) for lines outside any `variable "..." {` block.

    An object type constructor inside a variable block spells the same attribute names
    (`deletion_protection = optional(bool, true)`) and is a type expression, not a gate.
    """
    depth = 0
    in_var = False
    for i, line in enumerate(lines, 1):
        if not in_var and re.match(r'^\s*variable\s+"[^"]+"\s*\{', line):
            in_var, depth = True, line.count("{") - line.count("}")
            continue
        if in_var:
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                in_var = False
            continue
        yield i, line


def lever_locals(files):
    """Local names in this module whose definition derives from the lever."""
    names = set()
    for f in files:
        for _, line in strip_variable_blocks(f.read_text().splitlines()):
            m = re.match(r"^\s*([a-z0-9_]+)\s*=\s*(.+)$", line)
            if m and "var.force_destroy_buckets" in m.group(2):
                names.add(m.group(1))
    return names


def references_lever(expr, levers):
    return "var.force_destroy_buckets" in expr or any(f"local.{n}" in expr for n in levers)


def permissive_branch_ok(attr, expr, levers):
    """Does this expression resolve permissively when the lever is set?

    Bare lever (`force_destroy = local.allow_teardown`) is correct only where the
    permissive value is `true`. Anything else must spell the permissive branch out:
    `local.allow_teardown ? false : <pin>`.
    """
    want = GATES[attr]
    expr = expr.strip()
    if want == "true":
        return references_lever(expr, levers) and not re.match(r"^.*\?\s*false\b", expr)
    m = re.match(r"^(?P<cond>.+?)\s*\?\s*(?P<then>[a-z0-9_.\"]+)\s*:", expr)
    if not m:
        return False
    return references_lever(m.group("cond"), levers) and m.group("then").strip() == want


def main():
    repo = Path(__file__).resolve().parent.parent
    files_by_dir = defaultdict(list)
    for rel in tracked_tf_files():
        files_by_dir[rel.parent].append(repo / rel)

    failures = []
    inventory = []

    for d, files in sorted(files_by_dir.items()):
        text = "".join(f.read_text() for f in files)
        has_lever = 'variable "force_destroy_buckets"' in text
        levers = lever_locals(files) if has_lever else set()

        gated_here = 0
        for f in sorted(files):
            rel = f.relative_to(repo)
            for lineno, line in strip_variable_blocks(f.read_text().splitlines()):
                m = re.match(r"^\s*(" + "|".join(GATES) + r")\s*=\s*(.+?)\s*$", line)
                if not m:
                    continue
                attr, expr = m.group(1), m.group(2)
                gated_here += 1
                if not has_lever:
                    continue  # rule 2 covers this module as a whole
                if not permissive_branch_ok(attr, expr, levers):
                    failures.append(
                        f"::error file={rel},line={lineno}::{attr} does not open when the "
                        f"teardown lever is set: {attr} = {expr}\n"
                        f"    Every gate in a component that declares force_destroy_buckets must\n"
                        f"    resolve permissively on the lever-true branch, so a permitted teardown\n"
                        f"    reaches all of them in one destroy. Spell the branch out:\n"
                        f"      {attr} = <lever> ? {GATES[attr]} : <the leaf's own pin>"
                    )

        if has_lever:
            inventory.append(f"  {d}: lever + {gated_here} gate(s)")
            continue

        protectable = []
        for f in sorted(files):
            body = f.read_text()
            for rt in PROTECTABLE_RESOURCES:
                if re.search(r'^resource\s+"' + rt + r'"', body, re.M):
                    protectable.append(rt)
            for src in PROTECTABLE_MODULE_SOURCES:
                if re.search(r'^\s*source\s*=\s*"[^"]*' + src + r'[^"]*"', body, re.M):
                    protectable.append(f"module:{src}")
        if not protectable:
            continue

        key = str(d)
        if key in EXEMPT:
            inventory.append(f"  {key}: EXEMPT — {' '.join(EXEMPT[key].split())[:88]}…")
            continue
        failures.append(
            f"::error file={key}::creates {', '.join(sorted(set(protectable)))} but declares no "
            f"force_destroy_buckets, and is not in EXEMPT\n"
            f"    A component that can be applied and cannot be destroyed leaves a deployment\n"
            f"    you can validate exactly once. Either give it the lever every other\n"
            f"    substrate component has, or add it to EXEMPT in this script with the reason\n"
            f"    its resources must survive a teardown."
        )

    print("Teardown posture by module:")
    for line in inventory:
        print(line)
    print()

    if failures:
        for f in failures:
            print(f)
        print(f"\n{len(failures)} teardown-gate problem(s).")
        return 1

    print("Every teardown gate opens on the lever; every ungated module declares why.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
