#!/usr/bin/env python3
"""No tracked shell script uses a bash 4+ construct.

WHY THIS EXISTS

Every script here declares `#!/usr/bin/env bash`, which resolves to whatever
bash the machine has. CI runs Linux with bash 5. macOS ships bash 3.2 and has
since 2007 — Apple will not ship a newer one under GPLv3 — so a developer, a
release step, or an incident responder running these scripts on a Mac is on 3.2.

A bash 4 builtin on bash 3.2 does not warn. `mapfile` prints "command not
found"; in a script without `set -e` the array is length 0, the loop that
consumed it runs zero times, and the script exits 0 — so one that reads a list
and acts on each entry acts on nothing and reports success. In a teardown that
leaves resources billing behind a green run.

With `set -e` the failure is loud but not early: bash executes incrementally, so
every line above the construct has already run. A teardown aborts partway
through, which is a worse state than never starting.

The effects below were measured by running each construct under bash 3.2.57,
not reasoned about. Two of the eight did not behave the way the obvious reading
suggested — `&>>` is a parse error rather than a background-plus-append, and an
associative array without `set -e` silently collapses every key onto one slot
rather than merely erroring.

WHAT A LINTER DOES NOT CATCH

shellcheck parses; it does not run, and it cannot know which bash the reader
has. Given a script using mapfile, `declare -A` and `${x^^}` together it reports
none of them as a version requirement — it may object to something else on the
same line, which is worse, because the line gets attention and the portability
defect still ships. Being clean under shellcheck is not evidence of portability:
version compatibility is outside what it evaluates. The same question is worth
asking of every linter in a toolchain — what it actually evaluates, against what
it is assumed to cover.

WHAT IT CHECKS

Each construct below, in every tracked `.sh`. Waive on the using line with
`# bash4-ok: <reason>` when a script is genuinely CI-only.

VIEW

Comments are blanked. A construct named in prose — including this gate's own
explanation of what it forbids — is not a use of it. Both views are needed and
the raw text is read only for the waiver, which is itself a comment.

Exit 0 = every script runs on bash 3.2. Exit 1 = a construct that needs bash 4+.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# construct -> what it actually does on bash 3.2, measured by running each one
# under /bin/bash 3.2.57 rather than reasoned about. Two categories, and the
# difference decides how bad a given occurrence is:
#
#   PARSE   bash rejects the construct when it reaches that line. Lines ABOVE it
#           have already run, so a teardown aborts halfway through rather than
#           declining to start — the partial state is the damage.
#   RUNTIME the line fails. Under `set -e` the script aborts there; without it,
#           execution continues on a wrong value. 27 of the 28 scripts here set
#           -e, so for them these abort; `no-placeholders.sh` does not, and there
#           the failure is silent.
BASH4 = [
    (re.compile(r"\bmapfile\b"), "mapfile",
     "RUNTIME: `mapfile: command not found`. Under set -e the script aborts (rc 127); without it the array is length 0 and the loop over it runs zero times"),
    (re.compile(r"\breadarray\b"), "readarray",
     "RUNTIME: `readarray: command not found`; identical to mapfile"),
    (re.compile(r"\bcoproc\b"), "coproc",
     "PARSE: `syntax error near unexpected token` (rc 2), after the lines above it have already run"),
    (re.compile(r"\b(?:declare|local|typeset)\s+-A\b"), "associative array",
     "RUNTIME: `declare: -A: invalid option` (rc 2 under set -e). Without set -e it is worse than an error: every string index collapses to element 0, so writing two keys leaves one value that both keys read back"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\^\^"), "${x^^} upper-case",
     "RUNTIME: `bad substitution` (rc 1 under set -e)"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*,,"), "${x,,} lower-case",
     "RUNTIME: `bad substitution` (rc 1 under set -e)"),
    (re.compile(r";;&"), ";;& case fallthrough",
     "PARSE: `syntax error near unexpected token `&`` (rc 2), after the lines above it have already run"),
    (re.compile(r"&>>"), "&>> append-both redirect",
     "PARSE: `syntax error near unexpected token `>`` (rc 2) — bash 3.2 does not parse it as a redirect at all, so nothing about the line survives"),
]

WAIVER = re.compile(r"#[ \t]*bash4-ok:[ \t]*\S")


def blank_comments(text: str) -> str:
    """Blank comment interiors in SHELL, preserving length and line breaks.

    Shell has no `//` comment and `//` occurs in live code (a `sed 's//x/'`, a
    doubled path separator), so this must not treat it as one — unlike the HCL
    view in _hcl.py, which must.
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

    # Precondition, asserted rather than assumed. This gate knows one class:
    # bash 4 constructs in a script that runs under bash. A `#!/bin/sh` script
    # raises a DIFFERENT class — bashisms that Debian's dash rejects — and macOS
    # cannot surface it, because /bin/sh there is bash 3.2 in POSIX mode and
    # accepts them. Rather than check an sh script with bash rules and report a
    # pass, say what is not covered.
    non_bash = []
    for rel in scripts:
        first = (ROOT / rel).read_text().split("\n", 1)[0]
        if first.startswith("#!") and "bash" not in first:
            non_bash.append(f"  {rel}:1: {first}")
    if non_bash:
        print(
            "Script(s) that do not declare bash:\n\n" + "\n".join(non_bash) +
            "\n\nThis gate checks bash 4 constructs under bash. A POSIX-shell "
            "script needs the other check — bashisms that dash rejects — and "
            "this cannot answer it. Either give the script a bash shebang, or "
            "add a dash check that RUNS the script (dash -n is a syntax check "
            "and accepts constructs dash cannot execute).",
            file=sys.stderr,
        )
        return 1

    problems: list[str] = []
    for rel in scripts:
        raw = (ROOT / rel).read_text()
        code = blank_comments(raw)
        raw_lines = raw.splitlines()
        for n, line in enumerate(code.splitlines(), 1):
            for pattern, name, effect in BASH4:
                if not pattern.search(line):
                    continue
                if n <= len(raw_lines) and WAIVER.search(raw_lines[n - 1]):
                    continue
                problems.append(f"  {rel}:{n}: {name} — on bash 3.2, {effect}")

    if problems:
        print("bash 4+ construct(s) in a script that declares `env bash`:\n", file=sys.stderr)
        print("\n".join(problems), file=sys.stderr)
        print(
            "\nmacOS ships bash 3.2, so these fail for anyone running the script "
            "off a Mac — several of them silently, with exit 0. shellcheck does "
            "not object, because a static parser cannot know which interpreter "
            "the reader has. Rewrite in POSIX-compatible form (a `while IFS= "
            "read -r` loop replaces mapfile), or waive on the line with "
            "`# bash4-ok: <reason>`.",
            file=sys.stderr,
        )
        return 1

    print(
        f"✓ every shell script runs on bash 3.2 "
        f"({len(scripts)} script(s) checked for {len(BASH4)} bash 4+ construct(s))"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
