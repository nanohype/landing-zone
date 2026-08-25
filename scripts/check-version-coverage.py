#!/usr/bin/env python3
"""Every version pinned in this repo must be watched by something.

WHY THIS EXISTS

A pin nobody watches does not announce itself. It keeps working, keeps passing
CI, and goes stale silently until the upstream it names is retired or a CVE lands
on it — at which point the pin is discovered by the outage rather than by the
tooling.

Renovate's built-in managers cover the two obvious surfaces here: `.tf` files
(module versions, provider constraints) and the `uses:` line of a workflow step.
They cover neither of the surfaces this repo actually depends on most. The
github-actions manager updates the ACTION reference and never the version an
action is told to install, so `tofu_version: "1.11.5"` — the toolchain every job
in the build runs on — is invisible to it. A `pip install zizmor==...` in a run
step has no manifest at all.

WHAT IT CHECKS

Both halves of the invariant, because covering only the first is how this defect
survives:

  1. Every version-shaped pin the repo carries is matched by a Renovate manager —
     built-in by file type, or a customManager in renovate.json whose regex is
     applied here exactly as Renovate would apply it.

  2. Every file classified as carrying NO version is ASSERTED to carry none
     rather than described as carrying none. A description goes stale in silence;
     an assertion fails the build. That is the documentation rule made
     executable, and it is the half that catches a pin added to a file the
     coverage story had already written off.

A pin that genuinely must not be updated automatically is waived inline with the
reason:

    tofu_version: "1.11.5" # renovate-ok: pinned to match the provider lockfiles

Exit 0 = every pin is watched. Exit 1 = an unwatched pin, or the scan could not
see the tree.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

WAIVER = re.compile(r"#\s*renovate-ok:\s*\S")

# Attribute names that carry a version an upstream can retire. Curated rather
# than inferred: a bare "version-shaped string" matcher reports every CIDR,
# timeout and ACU setting in the tree, and a gate that cries wolf is turned off.
PIN_PATTERNS = [
    # (what it is, where it can appear, how it looks)
    #
    # Each pattern is scoped to the files that can legitimately carry it. An
    # unscoped `version = "x.y.z"` matcher reports every provider entry in every
    # .terraform.lock.hcl — hundreds of lines that ARE watched, by the terraform
    # manager, and that are generated besides. A gate whose first run is six dozen
    # false positives gets switched off, so the scoping is part of the check
    # working rather than a convenience.
    (
        "tool version input",
        re.compile(r"^\.github/workflows/"),
        re.compile(r"^\s*(?:tofu_version|tg_version|tflint_version|helm-version|terraform_version)\s*:\s*[\"']?v?\d+\.\d+", re.M),
    ),
    (
        "runtime version input",
        re.compile(r"^\.github/workflows/"),
        re.compile(r"^\s*(?:python-version|go-version|node-version)\s*:\s*[\"']\d+\.\d+", re.M),
    ),
    (
        "pip pin",
        re.compile(r"^\.github/workflows/"),
        re.compile(r"pip install\s+[a-zA-Z0-9._-]+==\d+\.\d+"),
    ),
    (
        "kubernetes control-plane version",
        re.compile(r"^components/aws/cluster/variables\.tf$"),
        re.compile(r"^\s*default\s*=\s*\"1\.\d+\"", re.M),
    ),
    (
        "tflint plugin version",
        re.compile(r"^\.tflint-aws\.hcl$"),
        re.compile(r"^\s*version\s*=\s*\"\d+\.\d+\.\d+\"", re.M),
    ),
]

# Generated artifacts. A finding against generated content routes to the source
# that generates it, and editing the artifact is undone by the next regeneration.
# Provider lockfiles are also already read by Renovate's terraform manager.
GENERATED = re.compile(r"\.terraform\.lock\.hcl$")

# Surfaces a built-in Renovate manager already reads. Listed with the manager
# that reads them, so a reader can check the claim rather than take it.
BUILTIN = [
    (re.compile(r"\.tf$"), "terraform manager: module source/version and required_providers"),
    (re.compile(r"^\.github/workflows/.+\.ya?ml$"), "github-actions manager: the `uses:` reference only"),
]

# Files asserted to carry no pin. Each entry is a claim this gate re-checks on
# every run: if a version appears in one of these, the run fails rather than the
# list quietly becoming wrong.
ASSERTED_NO_VERSION = {
    ".checkov.yaml": "a skip list keyed by check id; carries no upstream version",
    ".gitignore": "path patterns only",
    "renovate.json": "the watcher itself — its own regexes name versions it does not pin",
}


def tracked() -> list[str]:
    return subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()


def custom_managers() -> list[tuple[re.Pattern, list[re.Pattern], str]]:
    """Renovate's customManagers, compiled the way Renovate applies them.

    Reading the real config rather than restating it is the point: a manager
    deleted from renovate.json makes this gate fail, instead of this gate
    continuing to assert coverage that no longer exists.
    """
    cfg = json.loads((ROOT / "renovate.json").read_text())
    out = []
    for m in cfg.get("customManagers", []):
        files = []
        for pat in m.get("managerFilePatterns", []) + m.get("fileMatch", []):
            # Renovate wraps a regex file pattern in slashes; a bare string is a glob.
            files.append(re.compile(pat[1:-1] if pat.startswith("/") and pat.endswith("/") else re.escape(pat)))
        # Renovate's regexes are JavaScript-flavoured, where a named group is
        # `(?<name>...)`. Python spells the same thing `(?P<name>...)` and raises
        # on the other form, so translate rather than maintain a second copy of
        # each pattern — a second copy is what drifts.
        strings = [
            re.compile(re.sub(r"\(\?<(?![=!])", "(?P<", s))
            for s in m.get("matchStrings", [])
        ]
        out.append((files, strings, m.get("description", "<no description>")))
    return out


def main() -> int:
    files = tracked()
    if len(files) < 100:
        print(
            f"FAIL: only {len(files)} tracked files found (expected >= 100). The scan "
            f"could not see the tree; refusing to report a pass.",
            file=sys.stderr,
        )
        return 1

    managers = custom_managers()
    if not managers:
        print(
            "FAIL: renovate.json declares no customManagers. The built-in managers do "
            "not read tool-version inputs or bare pip pins, so with none of these every "
            "toolchain pin in this repo is unwatched.",
            file=sys.stderr,
        )
        return 1

    unwatched: list[str] = []
    broken_assertions: list[str] = []
    watched = 0

    for rel in files:
        path = ROOT / rel
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue

        if GENERATED.search(rel):
            continue

        hits = []
        for kind, scope, pat in PIN_PATTERNS:
            if not scope.search(rel):
                continue
            for m in pat.finditer(text):
                line_no = text[: m.start()].count("\n") + 1
                line = text.splitlines()[line_no - 1]
                if WAIVER.search(line):
                    continue
                hits.append((kind, line_no, line.strip()))

        # Half two: a file asserted to carry no version must actually carry none.
        if rel in ASSERTED_NO_VERSION and hits:
            broken_assertions.append(
                f"  {rel}: asserted to carry no version ({ASSERTED_NO_VERSION[rel]}), "
                f"but line {hits[0][1]} does: {hits[0][2]}"
            )
            continue

        for kind, line_no, line in hits:
            # Coverage is decided PER PIN, against the line the pin is on — not
            # per file. Asking whether any manager matches somewhere in the file
            # is the wrong question and it answers yes for the wrong reason: one
            # watched pin would vouch for every unwatched pin beside it, which is
            # exactly the shape this gate exists to catch.
            covered = False
            for file_pats, strings, _desc in managers:
                if not any(fp.search(rel) for fp in file_pats):
                    continue
                if any(s.search(line) for s in strings):
                    covered = True
                    break
            if covered:
                watched += 1
            else:
                builtin = next((why for pat, why in BUILTIN if pat.search(rel)), None)
                note = (
                    f" (the {builtin} does not reach this line)" if builtin else ""
                )
                unwatched.append(f"  {rel}:{line_no}: {kind}{note}\n      {line}")

    if broken_assertions:
        print(
            "File(s) asserted to carry no version now carry one:\n"
            + "\n".join(broken_assertions)
            + "\n\nThe assertion is the mechanism: a coverage claim that is merely "
            "described goes stale in silence. Either add a customManager for the pin "
            "or remove the file from ASSERTED_NO_VERSION.",
            file=sys.stderr,
        )
        return 1

    if unwatched:
        print("Version pin(s) no Renovate manager watches:\n", file=sys.stderr)
        print("\n".join(unwatched), file=sys.stderr)
        print(
            "\nAn unwatched pin does not announce itself — it keeps passing CI until "
            "the upstream it names is retired or a CVE lands on it. Add a "
            "customManager to renovate.json, or waive the pin inline with the reason "
            "it must not move:\n  <the pin> # renovate-ok: <why>",
            file=sys.stderr,
        )
        return 1

    print(
        f"✓ every version pin is watched ({watched} pin(s) matched by a customManager, "
        f"{len(ASSERTED_NO_VERSION)} file(s) asserted to carry none)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
