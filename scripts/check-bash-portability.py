#!/usr/bin/env python3
"""No tracked shell script uses a bash 4+ construct.

WHY THIS EXISTS

Every script here declares `#!/usr/bin/env bash`, which resolves to whatever
bash the machine has. CI runs Linux with bash 5. macOS ships bash 3.2 and has
since 2007 — Apple will not ship a newer one under GPLv3 — so a developer, a
release step, or an incident responder running these scripts on a Mac is on 3.2.

A bash 4 builtin on bash 3.2 does not warn. `mapfile` prints "command not found"
and the loop that consumed its array runs zero times, so a script that reads a
list and acts on each entry silently acts on nothing and exits 0. In a teardown
that means resources are left billing with a successful-looking run.

WHAT A LINTER DOES NOT CATCH

shellcheck parses; it does not run, and it cannot know which bash the reader
has. It reports nothing for any construct here — being clean under shellcheck is
not evidence of portability, because version compatibility is outside what it
evaluates. The same question is worth asking of every linter in a toolchain:
what does it actually evaluate, against what it is assumed to cover.

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

# construct -> what it does on bash 3.2
BASH4 = [
    (re.compile(r"\bmapfile\b"), "mapfile", "command not found; the array stays empty and the loop over it runs zero times"),
    (re.compile(r"\breadarray\b"), "readarray", "command not found; same silent empty array as mapfile"),
    (re.compile(r"\bcoproc\b"), "coproc", "syntax error; the script aborts"),
    (re.compile(r"\b(?:declare|local|typeset)\s+-A\b"), "associative array", "declare: -A: invalid option; every later index write lands on element 0"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\^\^"), "${x^^} upper-case", "bad substitution; the script aborts"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*,,"), "${x,,} lower-case", "bad substitution; the script aborts"),
    (re.compile(r";;&"), ";;& case fallthrough", "syntax error; the script aborts"),
    (re.compile(r"&>>"), "&>> append-both redirect", "parsed as background + append; stderr is not redirected"),
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
