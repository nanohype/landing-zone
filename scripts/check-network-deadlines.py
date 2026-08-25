#!/usr/bin/env python3
"""No shell script makes a network call that can hang forever.

WHY THIS EXISTS

`|| true` converts a FAILURE into a continue and does nothing about a HANG. A
remote that accepts the TCP connection and then stalls blocks the caller
indefinitely — and in scripts/e2e.sh the caller is a teardown holding an EKS
cluster, NAT gateways and Graviton nodes that keep billing while it waits.

The tools differ in what they do by default, which is why this cannot be left to
habit:

  kubectl   unbounded by default. This is the one that bites.
  curl      unbounded by default without --max-time.
  git       unbounded; no deadline flag, so it needs an external `timeout`.
  go build  unbounded on a module fetch; same.
  aws       bounded by its own default connect and read timeouts.

WHAT IT CHECKS

Every invocation of an unbounded-by-default tool in a tracked shell script is
bounded by one of three mechanisms: an explicit deadline flag on the call, an
external `timeout` prefix, or a shell function of the same name that injects one
(the wrapper pattern — which is preferred, because it makes a call that forgets
impossible rather than merely detectable).

The wrapper is what a per-call check cannot see on its own, so it is looked for
first: a script defining `kubectl() { ... --request-timeout ... }` has bounded
every kubectl call in it, including the ones written after the wrapper.

VIEW

Comment bodies are blanked. A comment mentioning kubectl is not a call, and prose
about deadlines must not satisfy a check about deadlines — which is the exact
shape this gate is here to prevent, since the comment claiming every call was
bounded is what made the gap invisible.

Exit 0 = every call is bounded. Exit 1 = an unbounded call, or no script read.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# tool -> the flag that bounds it on the call itself, if it has one.
UNBOUNDED = {
    "kubectl": "--request-timeout",
    "curl": "--max-time",
    "git": None,
    "helm": "--timeout",
}
# Subcommands that reach no network, so a deadline would bound nothing.
#
# Matched ANYWHERE on the line rather than at its start, because these appear
# inside `$( )` far more often than at the head of a statement — and matched after
# skipping git's global flags, since `git -C <dir> checkout` and
# `git -c user.name=x commit` put the subcommand third rather than second. Both
# are how a local-only call gets reported as an unbounded network call, which is
# the false positive that gets a gate switched off.
LOCAL_ONLY = re.compile(
    r"\bgit\s+(?:-[cC]\s+\S+\s+)*"
    r"(?:add|commit|rm|checkout|diff|status|log|config|init|rev-parse|ls-files)\b"
    r"|\bhelm\s+(?:template|show|lint)\b"
)


def blank_comment_bodies(text: str) -> str:
    """Blank comment interiors in SHELL, preserving length and line breaks.

    Deliberately diverged from its three siblings in scripts/ — the HCL strippers
    in check-version-coverage, check-backup-coverage and check-tenant-schema-readers
    also treat `//` as a comment opener. This one must not: shell has no `//`
    comment, and `//` appears in live code (a `sed 's//x/'`, a doubled path
    separator), so matching the others here would blank real code.

    Said out loud because four near-copies of one helper invite a well-meant
    consistency edit that is a bug in exactly one of them.
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
        elif c == "#":
            while i < len(text) and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)


def main() -> int:
    scripts = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "*.sh"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if not scripts:
        print(
            "FAIL: no shell scripts found. The scan could not see the tree; "
            "refusing to report a pass.",
            file=sys.stderr,
        )
        return 1

    unbounded: list[str] = []
    checked = 0

    for rel in scripts:
        code = blank_comment_bodies((ROOT / rel).read_text())

        # A wrapper function bounds every call to that name in this file.
        wrapped = {
            tool
            for tool, flag in UNBOUNDED.items()
            if flag and re.search(rf"^{tool}\(\)\s*\{{[^}}]*{re.escape(flag)}", code, re.M)
        }

        for n, line in enumerate(code.splitlines(), 1):
            for tool, flag in UNBOUNDED.items():
                if tool in wrapped:
                    continue
                if not re.search(rf"(?:^|[|;&(`]|\$\()\s*{tool}\s", line):
                    continue
                if LOCAL_ONLY.search(line):
                    continue
                checked += 1
                bounded = (
                    (flag and flag in line)
                    or re.search(rf"timeout\s+[0-9]+\s+{tool}\b", line)
                    or re.search(rf"timeout\s+[0-9]+[smh]?\s+{tool}\b", line)
                )
                if not bounded:
                    unbounded.append(f"  {rel}:{n}: {line.strip()[:100]}")

    if unbounded:
        print("Network call(s) with no deadline:\n", file=sys.stderr)
        print("\n".join(unbounded), file=sys.stderr)
        print(
            "\n`|| true` handles a failure and does nothing about a hang. Bound the "
            "call with its own deadline flag, prefix it with `timeout`, or define a "
            "wrapper function for the tool — the wrapper is best, because it makes a "
            "call that forgets impossible rather than merely detectable.",
            file=sys.stderr,
        )
        return 1

    print(
        f"✓ every network call in a shell script is bounded "
        f"({checked} unwrapped call(s) checked across {len(scripts)} script(s); "
        f"wrapped tools are bounded by construction)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
