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

WHAT THE FLOOR ASSERTS

Behaviour, not text. Whether a gate has a control is answered by the CONTENTS of
mutations() — a data structure — and then by running the gate twice: it must
ACCEPT the unmutated fixture and REJECT the mutated one. Both halves, because a
gate that rejects everything is exactly as useless as one that rejects nothing,
and either half alone passes a one-sided check.

A floor that decided this by grepping its own source for the word "control" could
be satisfied by a comment saying the controls were removed. This one cannot:
deleting a Mutation and leaving that comment in its place fails, and so does
neutering a gate to return non-zero unconditionally. Both were confirmed by doing
them.

FIXTURES

The controls patch a copy of the real tree rather than building fixtures from
literals. That is forced rather than preferred: these gates discover their inputs
through `git ls-files` over a repository, so a fixture has to BE a repository.
The cost is that a patch can fail to apply, which is why the landed-marker checks
below exist at all — a gate whose fixture can be constructed from literals needs
none of them, and should be written that way instead.

No control shells out to sed. Edits are Python string replacement, so there is no
BSD/GNU divergence to be silently no-opped by.

Exit 0 = every gate detected its violation. Exit 1 = a gate is blind, a gate has
no control, or the scan could not see the tree.
"""

from __future__ import annotations

import os
import pathlib
import re
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

    def __init__(self, gate: str, what: str, fn, marker: str | None = None):
        self.gate = gate
        self.what = what
        self.fn = fn
        # The text whose presence means the violation is really in the tree. A
        # changed file is not enough: a mutation can land, change bytes, and
        # change nothing that matters — planting a floor the tree already meets,
        # or editing a line the gate does not read. The marker closes that by
        # naming what was supposed to appear.
        self.marker = marker

    def apply(self, tree: Path) -> None:
        self.fn(tree)


# Every mutation helper proves it mutated, by comparing the text it wrote against
# the text it read. This is not belt-and-braces: a mutation that silently fails to
# mutate hands the gate an UNCHANGED fixture, the gate correctly passes it, and the
# run records that pass as evidence the control works. It fails in the
# safe-looking direction, which is why reading a control does not catch it.
#
# The realistic causes are all boring — an anchor that moved, a pattern spanning
# whitespace the file does not contain, a helper whose old and new arguments are
# equal after an edit. None of them announce themselves.


def _assert_changed(rel: str, before: str, after: str, what: str) -> None:
    if before == after:
        raise AssertionError(
            f"{what} left {rel} byte-identical. The fixture was not mutated, so any "
            f"verdict the gate returns about it is evidence of nothing."
        )


def _edit(tree: Path, rel: str, old: str, new: str) -> None:
    p = tree / rel
    if not p.exists():
        raise AssertionError(f"anchor file missing: {rel}")
    before = p.read_text()
    if old not in before:
        raise AssertionError(
            f"anchor not found in {rel}: {old!r}. The control cannot introduce its "
            f"violation, so it is no longer testing the matcher it names."
        )
    after = before.replace(old, new, 1)
    _assert_changed(rel, before, after, "_edit")
    p.write_text(after)


def _append(tree: Path, rel: str, text: str) -> None:
    p = tree / rel
    if not p.exists():
        raise AssertionError(f"anchor file missing: {rel}")
    before = p.read_text()
    after = before + text
    _assert_changed(rel, before, after, "_append")
    p.write_text(after)


# The token every mutation carries. Synthetic on purpose: a marker derived from
# real syntax is a marker that other files legitimately contain — another gate's
# docstring showing the shape it catches, a worked example in the tree — and then
# "already present" fires on text no control planted. This token appears nowhere
# but in a mutation.
def token(gate: str) -> str:
    return "blind-spot-control-" + gate.replace(".", "-")


# A finding that names a file and a line, in the ::error or the plain form both
# gates here use.
CITES_LINES = re.compile(r"(?:line=|:)\d+(?::|\b)")


def _first_citation(output: str) -> str:
    m = re.search(r"^.*?(?:line=|:)\d+.*$", output, re.M)
    return m.group(0).strip() if m else "<none>"


def touched_lines(tree: Path) -> set[int]:
    """Every line number the mutation added, read from the diff.

    The property is "the citation points at the mutation", not "the citation
    equals one particular line". A mutation spans lines — a comment above the
    violation, a block of several — and any line inside it is a correct place to
    send a reader. Anchoring on one chosen line would be asserting the
    implementation of the control rather than the behaviour of the gate.
    """
    diff = subprocess.run(
        ["git", "-C", str(tree), "diff", "--cached", "-U0", "HEAD"],
        capture_output=True, text=True, check=True,
    ).stdout
    lines: set[int] = set()
    for m in re.finditer(r"^@@ -\S+ \+(\d+)(?:,(\d+))? @@", diff, re.M):
        start = int(m.group(1))
        count = int(m.group(2) or 1)
        lines.update(range(start, start + count))
    return lines


def _contains(path: Path, needle: str) -> bool:
    try:
        return needle in path.read_text()
    except (UnicodeDecodeError, OSError):
        return False


def _write(tree: Path, rel: str, text: str) -> None:
    p = tree / rel
    before = p.read_text() if p.exists() else None
    if before == text:
        raise AssertionError(
            f"_write left {rel} byte-identical. The fixture was not mutated, so any "
            f"verdict the gate returns about it is evidence of nothing."
        )
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
                '\n# ' + token("check-account-local-deps.py") + '\n'
                'dependency "blind_spot_foreign_account" {\n'
                '  config_path = "../../../../network/us-east-1/development/shared-network"\n'
                "}\n",
            ),
            marker=token("check-account-local-deps.py"),
        ),
        Mutation(
            "check-architecture-components.sh",
            "a component in the tree is named by no table in docs/architecture.md",
            lambda t: _write(
                t,
                "components/aws/undocumented-thing/main.tf",
                "# " + token("check-architecture-components.sh") + "\n",
            ),
            marker=token("check-architecture-components.sh"),
        ),
        Mutation(
            "check-datastore-ingress-source.py",
            "a datastore ingress sources the cluster control-plane SG instead of the node SG",
            lambda t: _edit(
                t,
                "components/aws/tenant-substrate/modules/tenant/relational.tf",
                "source_security_group_id = var.node_sg_id",
                "source_security_group_id = var.cluster_sg_id # "
                + token("check-datastore-ingress-source.py"),
            ),
            marker=token("check-datastore-ingress-source.py"),
        ),
        Mutation(
            "check-documented-oidc-trust.py",
            "a document claims a bare :* OIDC subject the component does not emit",
            lambda t: _append(
                t,
                "docs/troubleshooting.md",
                "\nThe deploy role trusts `repo:nanohype/landing-zone:*`. "
                + token("check-documented-oidc-trust.py") + "\n",
            ),
            marker=token("check-documented-oidc-trust.py"),
        ),
        Mutation(
            "check-e2e-covers-leaves.py",
            "a live leaf is neither exercised by e2e.sh nor exempt with a reason",
            lambda t: _write(
                t,
                "live/aws/workload-development/us-east-1/development/uncovered-thing/terragrunt.hcl",
                "# " + token("check-e2e-covers-leaves.py") + "\n"
                'include "root" {\n  path = find_in_parent_folders("root.hcl")\n}\n',
            ),
            marker=token("check-e2e-covers-leaves.py"),
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
            marker="blind_spot_engine",
        ),
        Mutation(
            "check-escaped-interpolations.py",
            "an escaped interpolation sits on a CODE line, where HCL renders it literally",
            lambda t: _append(
                t,
                "live/_envcommon/aws/cluster.hcl",
                '\nlocals {\n  blind_spot = "$${var.escaped}"\n}\n',
            ),
            marker='blind_spot = "$${var.escaped}"',
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
            marker='arn:aws:iam::666666666666:role/other-account',
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
            marker='blind_spot_key',
        ),
        Mutation(
            "check-region-consistency.py",
            # region-ok: eu-west-1 IS the injected violation — a region no tree
            # deploys into is the whole point of this control, and the region gate
            # correctly reports it here, which is the two gates confirming each
            # other rather than a conflict.
            "prose names a region no live tree deploys into",
            lambda t: _append(t, "README.md", "\nDeploy into eu-west-1.\n"),
            marker='Deploy into eu-west-1.',
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
            marker='"aws:RequestTag/A" = "true"',
        ),
        Mutation(
            "check-smoke-outputs.py",
            "a smoke test reads an outputs.json key the component does not declare",
            lambda t: _append(
                t,
                "components/aws/observability/smoke-test.sh",
                "\nBLIND=$(jq -r '.blind_spot_output.value' outputs.json)\n",
            ),
            marker='blind_spot_output',
        ),
        Mutation(
            "check-teardown-gates.py",
            "a protectable resource pins a teardown gate closed while the lever is set",
            lambda t: _edit(
                t,
                "components/aws/tenant-substrate/modules/tenant/objectstore.tf",
                "force_destroy = local.allow_teardown",
                "force_destroy = false # local.allow_teardown "
                + token("check-teardown-gates.py"),
            ),
            marker=token("check-teardown-gates.py"),
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
            marker='blind_spot_field',
        ),
        Mutation(
            "check-version-coverage.py",
            "a workflow pins a tool version no Renovate customManager matches",
            # A real input line, not a commented one: the gate deliberately
            # ignores comments, so commenting the pin would test that it ignores
            # comments rather than that it catches an unwatched pin.
            lambda t: _edit(
                t,
                ".github/workflows/ci.yml",
                'python-version: "3.12"',
                'python-version: "3.12"\n          helm-version: "3.16"',
            ),
            marker='helm-version: "3.16"',
        ),
        Mutation(
            "check-roots-tested.py",
            "an OpenTofu root exists with no test suite",
            lambda t: _write(
                t,
                "components/aws/blind-spot-untested/versions.tf",
                "# " + token("check-roots-tested.py") + "\n"
                "terraform {\n  required_version = \">= 1.11.0\"\n}\n",
            ),
            marker=token("check-roots-tested.py"),
        ),
        Mutation(
            "check-network-deadlines.py",
            "a shell script makes a kubectl call with no deadline and no wrapper",
            lambda t: _write(
                t,
                "scripts/blind-spot-probe.sh",
                "#!/usr/bin/env bash\n"
                "# " + token("check-network-deadlines.py") + "\n"
                "set -euo pipefail\n"
                "kubectl get pods -A\n",
            ),
            marker=token("check-network-deadlines.py"),
        ),
        Mutation(
            "check-named-paths-resolve.py",
            "prose names a repo-relative path that does not exist",
            lambda t: _append(
                t,
                "README.md",
                "\n<!-- " + token("check-named-paths-resolve.py") + " -->\n"
                "See `docs/no-such-guide.md`.\n",
            ),
            marker=token("check-named-paths-resolve.py"),
        ),
        Mutation(
            "check-backup-coverage.py",
            "a backup-eligible bucket exists that no BackupPolicy tag can reach",
            lambda t: _append(
                t,
                "components/aws/model-import/main.tf",
                '\n# ' + token("check-backup-coverage.py") + '\n'
                'resource "aws_s3_bucket" "blind_spot_unprotectable" {\n'
                '  bucket = "blind-spot"\n'
                "  tags   = local.tags\n"
                "}\n",
            ),
            marker=token("check-backup-coverage.py"),
        ),
        Mutation(
            "check-workflow-budgets.py",
            "a workflow job has no timeout-minutes and inherits the 360-minute default",
            lambda t: _edit(
                t,
                ".github/workflows/ci.yml",
                "  placeholders:\n    name: Zero-placeholder gate\n    runs-on: ubuntu-latest\n    timeout-minutes: 10\n",
                "  placeholders:\n    name: Zero-placeholder gate\n    runs-on: ubuntu-latest\n",
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
            marker='# CHANGEME',
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
    # Commit, so a later `git diff HEAD` is a real question. Without a commit
    # every file reads as newly added forever and any "did the tree change?"
    # check answers yes unconditionally — a check that looks right and validates
    # nothing.
    subprocess.run(
        ["git", "-C", str(dest), "-c", "user.name=gate-controls",
         "-c", "user.email=gate-controls@localhost", "commit", "-q", "-m", "base"],
        check=True,
    )


def run_gate(tree: Path, gate: str) -> tuple[int, str]:
    script = tree / "scripts" / gate
    if not script.exists():
        # The scratch tree is built from `git ls-files`, so a gate that exists on
        # disk but is not tracked never arrives. That is worth saying plainly:
        # an untracked gate is also one CI would never run.
        raise AssertionError(
            f"{gate} is not tracked by git, so it was not copied into the scratch "
            f"tree — and CI would not run it either. `git add` it."
        )
    os.chmod(script, 0o755)
    cmd = ["python3", str(script)] if gate.endswith(".py") else ["bash", str(script)]
    proc = subprocess.run(
        cmd, cwd=tree, capture_output=True, text=True, timeout=300
    )
    return proc.returncode, proc.stdout + proc.stderr


ADVERSARIAL_PROBE = '''#!/usr/bin/env python3
"""Crashes ONLY on the bad fixture, with an exception naming the planted file."""
import pathlib, sys
MARKER = "-".join(["floor", "selftest", "planted"])
if MARKER in pathlib.Path("README.md").read_text():
    raise KeyError("README.md: unexpected key while checking README.md")
print("ok (1 file scanned)")
sys.exit(0)
'''


def self_test(base: Path) -> str | None:
    """Prove this floor rejects a gate that defeats both rules at once.

    The hardest liar is not one that always passes. It is one that fails ONLY on
    the bad fixture, with a message NAMING the planted file — that reads as a
    clean catch under exit-status and under name-the-mutation together, and only
    the traceback tells them apart.

    Runs on every ordinary invocation rather than behind a flag, so there is no
    step to forget and no flag a caller can silently drop. Returns None on
    success, or the reason the floor is not trustworthy.
    """
    tree = base.parent / "floor-selftest"
    if tree.exists():
        shutil.rmtree(tree)
    shutil.copytree(base, tree)

    probe = tree / "scripts" / "check-floor-selftest-probe.py"
    probe.write_text(ADVERSARIAL_PROBE)
    os.chmod(probe, 0o755)

    clean_code, clean_out = run_gate(tree, probe.name)
    if clean_code != 0:
        return f"the adversarial probe did not pass a clean fixture (exit {clean_code})"

    readme = tree / "README.md"
    readme.write_text(readme.read_text() + "\n<!-- floor-selftest-planted -->\n")
    bad_code, bad_out = run_gate(tree, probe.name)

    if bad_code == 0:
        return "the adversarial probe did not fail its own bad fixture"
    # This is the verdict rule under test: non-zero AND naming the planted file,
    # but a crash. The floor must call it a crash, not a catch.
    if not (bad_code != 1 or "Traceback (most recent call last)" in bad_out):
        return (
            "this floor would score a gate that CRASHES on the bad fixture as a "
            "catch — the crash exits non-zero and its message names the planted "
            "file, so neither the exit-status rule nor the name-the-mutation rule "
            "tells them apart on its own"
        )
    return None


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
    misreported: list[tuple[str, str]] = []

    with tempfile.TemporaryDirectory(prefix="gate-controls-") as tmp:
        base = Path(tmp) / "base"
        base.mkdir()
        copy_tree(base)

        # Before trusting any verdict this floor produces, prove the floor itself
        # rejects the hardest liar. A floor that cannot is reporting testimony.
        broken_floor = self_test(base)
        if broken_floor:
            print(
                f"FAIL: the floor's own self-test failed — {broken_floor}.\n"
                f"Every verdict below would be untrustworthy, so none is reported.",
                file=sys.stderr,
            )
            return 1

        for gate in sorted(shipped):
            m = controls[gate]
            tree = Path(tmp) / gate.replace(".", "_")
            shutil.copytree(base, tree)

            # The gate must be clean BEFORE the mutation, or a non-zero exit
            # afterwards proves nothing about the matcher.
            clean_code, clean_output = run_gate(tree, gate)
            if clean_code != 0:
                why = (
                    "crashes on the unmutated tree"
                    if "Traceback (most recent call last)" in clean_output
                    else "does not pass on the unmutated tree"
                )
                broken.append((
                    gate,
                    f"{why}: {clean_output.strip().splitlines()[-1][:120] if clean_output.strip() else '<no output>'}",
                ))
                continue

            # A marker that is ALREADY present cannot prove the control planted
            # it. This is the pre-existing-marker case, and it is the one that
            # reads as a clean pass: the gate rejects, the run records success,
            # and the control never had to do anything.
            before_texts = {}
            if m.marker:
                already = [
                    str(f.relative_to(tree))
                    for f in tree.rglob("*")
                    if f.is_file()
                    and ".git" not in f.parts
                    and f.name != Path(__file__).name
                    and _contains(f, m.marker)
                ]
                if already:
                    broken.append(
                        (
                            gate,
                            f"marker {m.marker!r} is already present in the unmutated "
                            f"tree ({already[0]}), so its presence afterwards proves "
                            f"nothing about the control.",
                        )
                    )
                    continue

            try:
                m.apply(tree)
            except AssertionError as exc:
                broken.append((gate, str(exc)))
                continue

            subprocess.run(["git", "-C", str(tree), "add", "-A"], check=True)

            # Second, independent proof that the fixture changed, taken from git
            # rather than from the helper. A helper that believes it wrote and did
            # not — a permissions failure, a path that resolved elsewhere — is
            # indistinguishable from a clean mutation until something outside it
            # looks.
            # And the marker must now be there. Bytes changed is the weaker
            # question; this is the one that asks whether what changed is the
            # thing the control claimed to introduce.
            if m.marker:
                found = any(
                    _contains(f, m.marker)
                    for f in tree.rglob("*")
                    if f.is_file()
                    and ".git" not in f.parts
                    and f.name != Path(__file__).name
                )
                if not found:
                    broken.append(
                        (
                            gate,
                            f"marker {m.marker!r} is absent after the mutation ran. "
                            f"Something changed, but not the thing this control says "
                            f"it plants.",
                        )
                    )
                    continue

            changed = subprocess.run(
                ["git", "-C", str(tree), "diff", "--cached", "--stat", "HEAD"],
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            if not changed:
                broken.append(
                    (
                        gate,
                        "the scratch tree is unchanged after the mutation ran. Whatever "
                        "the helper reported, nothing reached disk, so the gate's verdict "
                        "is about the original tree.",
                    )
                )
                continue

            code, output = run_gate(tree, gate)
            if code == 0:
                blind.append((gate, m.what))
                continue

            # A non-zero exit is not by itself a rejection: a gate that CRASHES
            # exits non-zero too, and the floor would read the traceback as
            # "detected the violation". That is the exit-code-conflates-causes
            # defect arriving inside the thing that checks for it. A rejection is
            # exit 1 with a diagnosis; anything else, or a Python traceback in the
            # output, means the gate did not answer the question.
            if code != 1 or "Traceback (most recent call last)" in output:
                misreported.append(
                    (
                        gate,
                        f"exited {code} on the mutated tree without answering — a "
                        f"crash, not a rejection. Tail: "
                        f"{output.strip().splitlines()[-1][:120] if output.strip() else '<no output>'}",
                    )
                )
                continue

            # Property, not mechanism: a gate that rejects but cites the wrong
            # line sends a reader to the wrong place, and no exit code shows it.
            # This is the check that survives a refactor — it asserts what a
            # citation must MEAN, rather than anything about how the gate
            # computes one, so a future change of matching strategy is judged by
            # the same standard as today's.
            #
            # Only asked of gates that cite lines at all: some report a whole
            # file, or a missing artifact, and demanding a line of them would be
            # asserting a shape they never claimed.
            # The rejection must NAME what was planted. Exit status alone is not
            # enough: a gate can reject the mutated fixture for a reason that has
            # nothing to do with the mutation — a pre-existing condition, an
            # unrelated file — and the floor would score that as proof it caught
            # the thing planted. Requiring the touched path in the output closes
            # the gap between "it failed" and "it found this".
            touched_files = {
                m.group(1)
                for m in re.finditer(
                    r"^\+\+\+ b/(\S+)",
                    subprocess.run(
                        ["git", "-C", str(tree), "diff", "--cached", "HEAD"],
                        capture_output=True, text=True, check=True,
                    ).stdout,
                    re.M,
                )
            }
            # Matched at the granularity gates actually report. A gate names the
            # thing it reasons about — a component, a live leaf, a module — which
            # is often the touched file's DIRECTORY rather than its full path:
            # "components/aws/ holds components no table names: undocumented-thing"
            # is a correct rejection naming the mutation. Requiring the exact path
            # would have failed four gates that were all reporting properly, which
            # is the rule being too strict rather than the gates being wrong.
            named = set()
            for f in touched_files:
                parts = pathlib.PurePosixPath(f).parts
                named.add(f)
                for i in range(1, len(parts)):
                    named.add("/".join(parts[:i]))
                    named.add(parts[i - 1])
                named.add(parts[-1])
            if touched_files and not any(
                n in output for n in named if len(n) > 3
            ):
                misreported.append(
                    (
                        gate,
                        f"rejected, but its output never names any file the "
                        f"mutation touched ({sorted(touched_files)[:3]}) — so it "
                        f"failed for some other reason, and this control proves "
                        f"nothing about the violation it planted.",
                    )
                )
                continue

            if CITES_LINES.search(output):
                cited = {int(x) for x in re.findall(r"(?:line=|:)(\d+)", output)}
                planted = touched_lines(tree)
                if planted and not (cited & planted):
                    misreported.append(
                        (
                            gate,
                            f"rejected, but every line it cited "
                            f"({sorted(cited)[:5]}) is outside the lines the "
                            f"mutation touched ({sorted(planted)[:5]}). "
                            f"Output: {_first_citation(output)}",
                        )
                    )

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

    if misreported:
        print("Gate(s) that did not answer, or answered about something else:\n", file=sys.stderr)
        for gate, why in misreported:
            print(f"  {gate}: {why}", file=sys.stderr)
        print(
            "\nThree different failures share this bucket and they are worth telling "
            "apart. A CRASH exits non-zero and looks identical to a rejection — the "
            "gate did not answer the question. A rejection that names nothing the "
            "mutation touched failed for some other reason, so the control proves "
            "nothing. A citation outside the mutated lines sends a reader where the "
            "violation is not; its usual cause is an anchor using \\s, which spans "
            "newlines and walks the match onto a neighbouring line.",
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
