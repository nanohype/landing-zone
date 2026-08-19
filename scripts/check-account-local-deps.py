#!/usr/bin/env python3
"""A workload environment must be installable from a standing start.

THE RULE. Nothing a workload leaf parses may reach into another account's
directory. A terragrunt cross-account reference resolves while the unit's config
is PARSED — before any tofu process starts — so no `TF_VAR` can bypass it and
`init` fails exactly as hard as `apply`. A leaf that reaches sideways is not
slow to bring up; it cannot be brought up at all.

WHY IT HAS TO BE A CHECK. Nothing else in CI can see it. The evaluate job
renders against `mock_outputs` by design, so a dependency with no state resolves
happily. The plan job green-skips unless both cloud variables are set. So a leaf
whose apply path cannot resolve stays green forever — which is how a deliberate,
well-reviewed change once made the default environment un-installable.

WHY THIS REPLACED A NARROWER CHECK. The previous version asked which SYNTAX was
used. It began by inspecting `dependency` blocks, was widened to "every
config_path in the file, whether or not it is on a dependency line" — and still
missed `live/_envcommon/aws/backup.hcl`, which reaches into the backup account
through `read_terragrunt_config`. Twice, on two independent counts: `_envcommon`
is not under `live/aws/workload-*` so the scope skipped the file entirely, and
`read_terragrunt_config` is not `config_path` so the mechanism would not have
seen it even in scope.

Widening by enumeration does not converge — each pass adds the one pattern that
just escaped. So this no longer asks which FUNCTION carried the path: any string
literal is a candidate, whether it sat on a `config_path`, a
`read_terragrunt_config`, a `file()`, or a function nobody has used yet.

WHAT IT DOES NOT DO, stated because the sentence above would otherwise promise
more than the code delivers. Having stopped enumerating functions, this still
enumerates the PATH FORMS it can resolve:

  - in a leaf: a literal beginning `../`, `./` or `live/`, resolved against the
    leaf's own directory.
  - in `_envcommon`: the `${dirname(find_in_parent_folders("cloud.hcl"))}/<seg>/`
    idiom, which is how a shared file addresses a sibling of the cloud root.

A path assembled from a local or a variable, an absolute path, or an anchoring
idiom other than the one above is NOT matched. Nothing in the tree uses those
forms today — every `_envcommon` traversal is cloud.hcl-anchored and every
`config_path` is a single-level `../sibling` — so the guard is correct here and
now, not correct by construction.

Resolving instead of pattern-matching is the version that would converge, and it
is not free: it needs terragrunt to evaluate the config, and `_envcommon` cannot
be evaluated standalone — it only has meaning through the leaf that includes it.
So this is a deliberate trade, recorded rather than hidden. IF YOU ADD A NEW PATH
IDIOM, THIS GUARD DOES NOT AUTOMATICALLY COVER IT.

TWO SCOPES, because "its own account" means different things.

  live/aws/<account>/...   a leaf's own account is <account>. A literal that
                           resolves outside `live/aws/<account>/` is foreign.

  live/_envcommon/...      shared by EVERY account, so it has no own account. A
                           literal naming any specific account directory makes
                           every leaf that includes it reach into that account —
                           which is exactly how one file put a cross-account read
                           into all of them at once.

Exit 0 = clean. Exit 1 = a foreign reference, or a scan that could not see the tree.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIVE = ROOT / "live" / "aws"

# A reference that is allowed to name a foreign account, and why. An entry here
# is a decision someone wrote down; a reference missing from both this table and
# the rule is an accident that reads identically.
EXEMPT: dict[str, str] = {
    "live/_envcommon/aws/backup.hcl": (
        "Reads the backup account's account.hcl and its DR-region region.hcl to compose "
        "the central vault ARN. Deliberate, and the reasoning is at backup.hcl:19-40: it "
        "reads the SAME region.hcl the shared-backup leaves sit under, so moving the DR "
        "region is one file rather than a constant here and another under live/aws/backup/. "
        "It also gates on the placeholder — an unprovisioned backup account yields an empty "
        "ARN and no copy_action at all, rather than a durability claim terminating nowhere. "
        "This is a cross-account READ of configuration, not a dependency on another "
        "account's STATE: it resolves from files in this repo and needs no remote state, so "
        "it cannot make an environment un-installable, which is what the rule protects."
    ),
}


def accounts() -> set[str]:
    return {p.name for p in LIVE.iterdir() if p.is_dir()}


def tracked_hcl() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "live/**/*.hcl", "live/*.hcl"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [ROOT / rel for rel in out]


# Any double-quoted literal. The point is to be indifferent to which function
# carried it — config_path, read_terragrunt_config, file(), or one not invented yet.
LITERAL = re.compile(r'"([^"\n]+)"')
# `${dirname(find_in_parent_folders("cloud.hcl"))}/<segment>/...` — the idiom that
# addresses a sibling of the cloud root, i.e. an account directory.
FROM_CLOUD_ROOT = re.compile(r'cloud\.hcl"\)\)\}/([^/"]+)/')


def violations(path: Path, account_names: set[str]) -> list[str]:
    rel_path = path.relative_to(ROOT).as_posix()
    if rel_path in EXEMPT:
        return []

    text = path.read_text()
    found: list[str] = []
    parts = Path(rel_path).parts

    # ---- shared wiring: naming ANY account directory is the violation --------
    if parts[:2] == ("live", "_envcommon"):
        for seg in FROM_CLOUD_ROOT.findall(text):
            if seg in account_names:
                found.append(
                    f"names the '{seg}' account directory. _envcommon is included by every "
                    f"account, so this makes every including leaf reach into '{seg}'."
                )
        return found

    # ---- a live leaf: its own account directory is the boundary -------------
    if parts[:2] != ("live", "aws") or len(parts) < 3:
        return []
    own = parts[2]
    if not own.startswith("workload-"):
        return []  # cross-account wiring outside workload-* is legitimate (adopt mode)

    account_dir = f"live/aws/{own}"
    leaf_dir = path.parent
    for lit in LITERAL.findall(text):
        if "/" not in lit or lit.startswith("${"):
            continue
        # Only resolve things that look like filesystem paths into the tree.
        if not (lit.startswith("../") or lit.startswith("./") or lit.startswith("live/")):
            continue
        resolved = Path(os.path.normpath(leaf_dir / lit))
        try:
            rel = resolved.relative_to(ROOT).as_posix()
        except ValueError:
            continue
        if rel.startswith("live/aws/") and not rel.startswith(account_dir + "/"):
            found.append(
                f"path literal '{lit}' resolves to '{rel}', outside {account_dir}."
            )
    return found


def main() -> int:
    if not LIVE.is_dir():
        print(f"FAIL: {LIVE} is missing — the subject of this check", file=sys.stderr)
        return 1

    account_names = accounts()
    files = tracked_hcl()

    # Anti-vacuity: measure what was INSPECTED, not what was listed. A run that
    # saw nothing must fail rather than print a reassuring zero.
    if len(files) < 50 or len(account_names) < 3:
        print(
            f"FAIL: inspected {len(files)} hcl files across {len(account_names)} account "
            f"directories (expected >= 50 and >= 3). The scan could not see the tree; "
            f"refusing to report a pass.",
            file=sys.stderr,
        )
        return 1

    bad: list[tuple[str, str]] = []
    for f in files:
        for msg in violations(f, account_names):
            bad.append((f.relative_to(ROOT).as_posix(), msg))

    if bad:
        print("Cross-account reference(s) from a workload-installable path:\n", file=sys.stderr)
        for rel, msg in bad:
            print(f"  {rel}: {msg}", file=sys.stderr)
        print(
            "\nA terragrunt cross-account reference resolves at config-parse time, so it "
            "fails `init` before tofu starts and no TF_VAR bypasses it — the environment "
            "cannot be brought up at all.\n"
            "Put cross-account worked examples under live/aws/reference-adopt/, which is "
            "rendered and read but never applied. If a reference is genuinely required, "
            "add it to EXEMPT in this script with the reason.",
            file=sys.stderr,
        )
        return 1

    print(
        f"✓ no workload leaf or shared include reaches another account "
        f"({len(files)} hcl files, {len(account_names)} accounts, {len(EXEMPT)} documented exemption)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
