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


def blank_comment_bodies(text: str) -> str:
    """Replace the inside of every comment with spaces, keeping length and lines.

    Two views of the same file, because two different questions are being asked
    of it and one view cannot answer both:

      raw       — for the waiver and for the manager match. A `renovate-ok:`
                  waiver IS a comment, so a stripped view cannot see it. And
                  Renovate matches raw file content, so a manager check that read
                  anything else would be answering a different question than the
                  tool it is modelling.

      blanked   — for pin DETECTION. A version quoted inside a comment is prose
                  about a pin, not a pin, and reporting it sends someone to add a
                  customManager for a line that installs nothing.

    Bodies are blanked rather than deleted so offsets and line numbers survive
    and the file:line in a finding still points where it says it does.
    """
    out, quote, i = [], None, 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\" and i + 1 < len(text):
                out.append(text[i : i + 2]); i += 2; continue
            if c == quote:
                quote = None
            out.append(c)
        elif c in "\"'":
            quote = c
            out.append(c)
        elif c == "#" or text[i : i + 2] == "//":
            while i < len(text) and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)

# Attribute names that carry a version an upstream can retire. Curated rather
# than inferred: a bare "version-shaped string" matcher reports every CIDR,
# timeout and ACU setting in the tree, and a gate that cries wolf is turned off.
PIN_PATTERNS = [
    # (what it is, where it can appear, how it looks)
    #
    # Leading whitespace is [ \t]* rather than \s*, which is load-bearing against
    # the blanked view: a comment line becomes all spaces there, and \s* spans
    # newlines, so the anchor would swallow the annotation line above a pin and
    # report the wrong line — which then fails the manager match that keys on the
    # pin's own trailing annotation.
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
        re.compile(r"^[ \t]*(?:tofu_version|tg_version|tflint_version|helm-version|terraform_version|TERRAGRUNT_VERSION)[ \t]*:[ \t]*[\"']?v?\d+\.\d+", re.M),
    ),
    (
        "runtime version input",
        re.compile(r"^\.github/workflows/"),
        re.compile(r"^[ \t]*(?:python-version|go-version|node-version)\s*:\s*[\"']\d+\.\d+", re.M),
    ),
    (
        "pip pin",
        re.compile(r"^\.github/workflows/"),
        re.compile(r"pip install\s+[a-zA-Z0-9._-]+==\d+\.\d+"),
    ),
    (
        "eks addon version",
        re.compile(r"^components/aws/cluster/variables\.tf$"),
        re.compile(r"^[ \t]*[a-z-]+[ \t]*=[ \t]*\"v\d+\.\d+\.\d+-eksbuild\.\d+\"", re.M),
    ),
    (
        "kubernetes control-plane version",
        re.compile(r"^components/aws/cluster/variables\.tf$"),
        re.compile(r"^[ \t]*default[ \t]*=[ \t]*\"1\.\d+\"", re.M),
    ),
    (
        "tflint plugin version",
        re.compile(r"^\.tflint-aws\.hcl$"),
        re.compile(r"^[ \t]*version[ \t]*=[ \t]*\"\d+\.\d+\.\d+\"", re.M),
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

    # An exemption that matches nothing is a description, and it rots toward
    # permissive: the file it named is gone, the entry stays, and the next file
    # to take that path inherits an exemption nobody granted it.
    missing_assertions = [
        rel for rel in ASSERTED_NO_VERSION if not (ROOT / rel).exists()
    ]
    if missing_assertions:
        print(
            "File(s) asserted to carry no version no longer exist:\n"
            + "".join(f"  - {r}\n" for r in sorted(missing_assertions))
            + "\nAn exemption naming nothing exempts nothing today and something "
            "unintended tomorrow. Remove the entry.",
            file=sys.stderr,
        )
        return 1

    unwatched: list[str] = []
    broken_assertions: list[str] = []
    watched = 0
    # Which managers actually matched. A customManager that matches nothing is
    # dead config: it reads as coverage, Renovate silently updates nothing
    # through it, and this gate would count the pin as watched by a rule that
    # never fires.
    manager_hits = {desc: 0 for _f, _s, desc in managers}

    for rel in files:
        path = ROOT / rel
        try:
            text = path.read_text()
        except (UnicodeDecodeError, OSError):
            continue

        if GENERATED.search(rel):
            continue

        # The blanked view is what pin detection reads; `text` stays raw for the
        # waiver and the manager match below.
        code = blank_comment_bodies(text)

        hits = []
        for kind, scope, pat in PIN_PATTERNS:
            if not scope.search(rel):
                continue
            for m in pat.finditer(code):
                line_no = code[: m.start()].count("\n") + 1
                # The RAW line — the waiver on it is a comment, and a blanked
                # view would report every waived pin as unwaived.
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
                    manager_hits[_desc] += 1
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

    # The one EKS-addon relationship that is checkable. kube-proxy is versioned in
    # lockstep with the control plane — its addon build for a 1.36 cluster is
    # v1.36.x-eksbuild.N — so a cluster_version bump that leaves the addon map
    # behind pins a kube-proxy built for the previous minor. AWS accepts the
    # combination within its skew window and then stops, which makes this the
    # failure the map exists to prevent and the one worth asserting rather than
    # describing.
    cluster_vars = (ROOT / "components/aws/cluster/variables.tf").read_text()
    k8s = re.search(r'default\s*=\s*"(1\.\d+)"\s*#\s*k8s-version', cluster_vars)
    kube_proxy = re.search(r'kube-proxy\s*=\s*"v(\d+\.\d+)\.\d+-eksbuild\.\d+"', cluster_vars)
    if not k8s or not kube_proxy:
        print(
            "FAIL: could not locate cluster_version or the kube-proxy addon pin in "
            "components/aws/cluster/variables.tf. One of them moved, and this check "
            "cannot silently stop asserting their relationship.",
            file=sys.stderr,
        )
        return 1
    if k8s.group(1) != kube_proxy.group(1):
        print(
            f"FAIL: kube-proxy addon is pinned to {kube_proxy.group(1)} while "
            f"cluster_version is {k8s.group(1)}.\n"
            f"    kube-proxy tracks the control-plane minor. Re-pin the addon map "
            f"alongside cluster_version:\n"
            f"      aws eks describe-addon-versions --kubernetes-version {k8s.group(1)}",
            file=sys.stderr,
        )
        return 1

    dead = [d for d, n in manager_hits.items() if n == 0]
    if dead:
        print(
            "Renovate customManager(s) that match nothing in this tree:\n"
            + "".join(f"  - {d}\n" for d in dead)
            + "\nA rule matching nothing is dead config. It reads as coverage on "
            "the page, updates nothing in practice, and makes this gate count a pin "
            "as watched by a rule that never fires. Fix its pattern or delete it.",
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
        f"✓ every version pin is watched ({watched} pin(s) across "
        f"{len(manager_hits)} live customManager(s); "
        f"{len(ASSERTED_NO_VERSION)} file(s) asserted to carry none)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
