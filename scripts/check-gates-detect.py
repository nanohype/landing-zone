#!/usr/bin/env python3
"""Every gate must fail on a violation it claims to catch.

WHY THIS EXISTS

The check-* scripts carry the assertions no `tofu test` can reach: teardown-gate
polarity, tenant-field readers, SCP satisfiability, engine-version pins, region
consistency, cross-account dependencies. They are roughly a hundred kilobytes of
regex over HCL, and a regex has a failure mode a type system does not: it stops
matching, and the gate keeps exiting 0.

Nothing about that failure looks like a failure. The job is green, the summary
line reports a count, and the count is of files scanned rather than violations
found — so a gate that has gone blind is indistinguishable from a clean tree.

The gates already guard the vacuous direction: each refuses to report a pass when
its own scan comes back implausibly empty. That catches a broken glob or a wrong
cwd. It does not catch the narrower and likelier break, where the scan still sees
the tree and the matcher no longer recognises what it is looking at.

WHAT IT CHECKS

For each gate, a POSITIVE CONTROL: copy the tree, introduce one violation that
gate exists to catch, and require a non-zero exit. A gate that passes over its own
violation is reported as blind.

The mutation is stated per gate below, in the terms the gate reasons about, so a
reader can tell whether the control actually exercises the matcher or merely
something adjacent. A control that mutates the wrong thing is worse than none: it
reports coverage the matcher does not have.

This harness is itself a gate and runs alongside the others. It excludes itself,
which is a real limit rather than an oversight — nothing here positively controls
the harness, so a break in it fails open. Its own anti-vacuity floor is the
partial compensation: it refuses to report a pass unless it exercised a control
for every gate the repo ships.

Exit 0 = every gate detected its violation. Exit 1 = a gate is blind, a gate has
no control, or the scan could not see the tree.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# This file, and the entry points that are not violation-detecting gates.
NOT_A_GATE = {
    "check-gates-detect.py",  # the harness; see the limit stated in the docstring
}


class Mutation:
    """One violation, described in the gate's own terms.

    `apply` edits the copied tree and returns a short description of what it did,
    or raises if the anchor it needed is not there — an anchor that has moved
    means the control is no longer exercising what it claims to, and that must
    fail loudly rather than silently test nothing.
    """

    def __init__(self, gate: str, what: str, fn):
        self.gate = gate
        self.what = what
        self.fn = fn

    def apply(self, tree: Path) -> None:
        self.fn(tree)


def _edit(tree: Path, rel: str, old: str, new: str) -> None:
    p = tree / rel
    text = p.read_text()
    if old not in text:
        raise AssertionError(
            f"anchor not found in {rel}: {old!r}. The control cannot introduce its "
            f"violation, so it is no longer testing the matcher it names."
        )
    p.write_text(text.replace(old, new, 1))


def _append(tree: Path, rel: str, text: str) -> None:
    p = tree / rel
    if not p.exists():
        raise AssertionError(f"anchor file missing: {rel}")
    p.write_text(p.read_text() + text)


def _write(tree: Path, rel: str, text: str) -> None:
    p = tree / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def mutations() -> list[Mutation]:
    return [
        Mutation(
            "check-account-local-deps.py",
            "a workload leaf takes a dependency on another account's directory",
            lambda t: _append(
                t,
                "live/aws/workload-development/us-east-1/development/network/terragrunt.hcl",
                '\ndependency "foreign" {\n'
                '  config_path = "../../../../network/us-east-1/development/shared-network"\n'
                "}\n",
            ),
        ),
        Mutation(
            "check-architecture-components.sh",
            "a component in the tree is named by no table in docs/architecture.md",
            lambda t: _write(
                t,
                "components/aws/undocumented-thing/main.tf",
                "# a component the architecture doc has never heard of\n",
            ),
        ),
        Mutation(
            "check-datastore-ingress-source.py",
            "a datastore ingress sources the cluster control-plane SG instead of the node SG",
            lambda t: _edit(
                t,
                "components/aws/tenant-substrate/modules/tenant/relational.tf",
                "source_security_group_id = var.node_sg_id",
                "source_security_group_id = var.cluster_sg_id",
            ),
        ),
        Mutation(
            "check-documented-oidc-trust.py",
            "a document claims a bare :* OIDC subject the component does not emit",
            lambda t: _append(
                t,
                "docs/troubleshooting.md",
                "\nThe deploy role trusts `repo:nanohype/landing-zone:*`.\n",
            ),
        ),
        Mutation(
            "check-e2e-covers-leaves.py",
            "a live leaf is neither exercised by e2e.sh nor exempt with a reason",
            lambda t: _write(
                t,
                "live/aws/workload-development/us-east-1/development/uncovered-thing/terragrunt.hcl",
                'include "root" {\n  path = find_in_parent_folders("root.hcl")\n}\n',
            ),
        ),
        Mutation(
            "check-engine-version-pins.py",
            "a managed-engine version is pinned to a minor AWS can withdraw",
            lambda t: _append(
                t,
                "components/aws/druid/modules/tenant/aurora.tf",
                '\nlocals {\n  blind_spot_engine = "16.6"\n}\n'
                'resource "terraform_data" "blind_spot" {\n'
                '  engine_version = "16.6"\n'
                "}\n",
            ),
        ),
        Mutation(
            "check-escaped-interpolations.py",
            "an escaped interpolation sits on a CODE line, where HCL renders it literally",
            lambda t: _append(
                t,
                "live/_envcommon/aws/cluster.hcl",
                '\nlocals {\n  blind_spot = "$${var.escaped}"\n}\n',
            ),
        ),
        Mutation(
            "check-foreign-placeholders.py",
            "an appliable workload leaf names another account's placeholder id",
            lambda t: _append(
                t,
                "live/aws/workload-development/us-east-1/development/network/terragrunt.hcl",
                "\ninputs = {\n"
                '  blind_spot = "arn:aws:iam::666666666666:role/other-account"\n'
                "}\n",
            ),
        ),
        Mutation(
            "check-mock-outputs.py",
            "a dependency mock declares a key the upstream component does not output",
            lambda t: _edit(
                t,
                "live/_envcommon/aws/cluster-addons.hcl",
                "mock_outputs = {",
                "mock_outputs = {\n    blind_spot_key = \"no such output\"",
            ),
        ),
        Mutation(
            "check-region-consistency.py",
            "prose names a region no live tree deploys into",
            lambda t: _append(t, "README.md", "\nDeploy into eu-west-1.\n"),
        ),
        Mutation(
            "check-scp-deny-can-fire.py",
            "a Deny carries a multi-key Null condition, so it can never be satisfied",
            lambda t: _edit(
                t,
                "live/aws/management/us-east-1/org/org-scp/terragrunt.hcl",
                '            Resource = "*"\n          },',
                '            Resource = "*"\n'
                "            Condition = {\n"
                "              Null = {\n"
                '                "aws:RequestTag/A" = "true"\n'
                '                "aws:RequestTag/B" = "true"\n'
                "              }\n"
                "            }\n"
                "          },",
            ),
        ),
        Mutation(
            "check-smoke-outputs.py",
            "a smoke test reads an outputs.json key the component does not declare",
            lambda t: _append(
                t,
                "components/aws/observability/smoke-test.sh",
                "\nBLIND=$(jq -r '.blind_spot_output.value' outputs.json)\n",
            ),
        ),
        Mutation(
            "check-teardown-gates.py",
            "a protectable resource pins a teardown gate closed while the lever is set",
            lambda t: _edit(
                t,
                "components/aws/tenant-substrate/modules/tenant/objectstore.tf",
                "force_destroy = local.allow_teardown",
                "force_destroy = false # local.allow_teardown",
            ),
        ),
        Mutation(
            "check-tenant-schema-readers.py",
            "a tenants field has no reader, and a COMMENT mentioning it stands where the "
            "implementation should be — the shape a substring match agrees with",
            lambda t: (
                _edit(
                    t,
                    "components/aws/governance/variables.tf",
                    "type = map(object({",
                    "type = map(object({\n    blind_spot_field = optional(bool, false)",
                ),
                # The control is deliberately the harder case. A field with no
                # mention at all is caught by any matcher; a field whose only
                # occurrence is prose explaining its absence is caught only by one
                # that strips comments, and prose is what actually sits there.
                _append(
                    t,
                    "components/aws/governance/main.tf",
                    "\n# blind_spot_field is declared but not yet wired to a resource.\n"
                    "# A tenant setting .blind_spot_field sees it accepted.\n",
                ),
            ),
        ),
        Mutation(
            "no-placeholders.sh",
            "a placeholder sentinel survives into deploy config",
            lambda t: _append(
                t,
                ".github/workflows/deploy.yml",
                "\n# CHANGEME\n",
            ),
        ),
    ]


def shipped_gates() -> set[str]:
    names = set()
    for p in sorted(ROOT.joinpath("scripts").glob("check-*.py")):
        names.add(p.name)
    for p in sorted(ROOT.joinpath("scripts").glob("check-*.sh")):
        names.add(p.name)
    names.add("no-placeholders.sh")
    return names - NOT_A_GATE


def copy_tree(dest: Path) -> None:
    """A git checkout of the tracked tree. The gates read `git ls-files`, so the
    copy has to be a repository rather than a directory of files."""
    tracked = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split("\n")
    for rel in tracked:
        if not rel:
            continue
        src = ROOT / rel
        if not src.is_file():
            continue
        out = dest / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, out)
    subprocess.run(["git", "-C", str(dest), "init", "-q"], check=True)
    subprocess.run(["git", "-C", str(dest), "add", "-A"], check=True)


def run_gate(tree: Path, gate: str) -> int:
    script = tree / "scripts" / gate
    os.chmod(script, 0o755)
    cmd = ["python3", str(script)] if gate.endswith(".py") else ["bash", str(script)]
    proc = subprocess.run(
        cmd, cwd=tree, capture_output=True, text=True, timeout=300
    )
    return proc.returncode


def main() -> int:
    shipped = shipped_gates()
    controls = {m.gate: m for m in mutations()}

    # Anti-vacuity, and the reason this harness has teeth: a gate added without a
    # control here would otherwise be reported as covered by a suite that never
    # ran anything against it.
    uncovered = shipped - set(controls)
    if uncovered:
        print(
            "FAIL: gate(s) ship with no positive control here:\n"
            + "".join(f"  - {g}\n" for g in sorted(uncovered))
            + "\nAdd a mutation to mutations() that introduces exactly the violation "
            "the gate exists to catch. A gate with no control is a gate nothing "
            "proves is still looking.",
            file=sys.stderr,
        )
        return 1

    stale = set(controls) - shipped
    if stale:
        print(
            "FAIL: control(s) name a gate that no longer exists:\n"
            + "".join(f"  - {g}\n" for g in sorted(stale)),
            file=sys.stderr,
        )
        return 1

    blind: list[tuple[str, str]] = []
    broken: list[tuple[str, str]] = []

    with tempfile.TemporaryDirectory(prefix="gate-controls-") as tmp:
        base = Path(tmp) / "base"
        base.mkdir()
        copy_tree(base)

        for gate in sorted(shipped):
            m = controls[gate]
            tree = Path(tmp) / gate.replace(".", "_")
            shutil.copytree(base, tree)

            # The gate must be clean BEFORE the mutation, or a non-zero exit
            # afterwards proves nothing about the matcher.
            if run_gate(tree, gate) != 0:
                broken.append((gate, "does not pass on the unmutated tree"))
                continue

            try:
                m.apply(tree)
            except AssertionError as exc:
                broken.append((gate, str(exc)))
                continue

            subprocess.run(["git", "-C", str(tree), "add", "-A"], check=True)

            if run_gate(tree, gate) == 0:
                blind.append((gate, m.what))

    if broken:
        print("Control(s) could not be run:\n", file=sys.stderr)
        for gate, why in broken:
            print(f"  {gate}: {why}", file=sys.stderr)
        print(
            "\nA control that cannot introduce its violation is testing nothing. "
            "Re-anchor it on something the gate still reasons about.",
            file=sys.stderr,
        )
        return 1

    if blind:
        print("Gate(s) passed over the violation they exist to catch:\n", file=sys.stderr)
        for gate, what in blind:
            print(f"  {gate}\n      injected: {what}", file=sys.stderr)
        print(
            "\nThe gate exited 0 with the violation present, so it is no longer "
            "detecting it — most often a pattern that stopped matching after the "
            "tree moved around it. Fix the matcher; the passing exit code is the "
            "symptom, not the bug.",
            file=sys.stderr,
        )
        return 1

    print(f"✓ every gate detects its own violation ({len(shipped)} positive controls)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
