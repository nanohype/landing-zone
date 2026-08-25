#!/usr/bin/env python3
"""Every repo path named in prose must exist.

WHY THIS EXISTS

Prose that names a thing is a claim about the world. A path in a README, a script
in a runbook step, a component in an architecture table — each one is a promise
that something is there, and each one is checkable. Nothing was checking them.

The failure is quiet and it lands on the reader rather than the author. A path
that stops resolving does not break a build; it wastes the time of whoever
follows it, and it teaches them that the documentation is approximate. This repo
already learned that once: CLAUDE.md named a gate as `.sh` when the file is `.py`,
in the one document every session in this repository loads.

It also rots one-directionally. Renaming a file updates every import and no
sentence, so the prose is always the half that goes stale, and it goes stale
silently in exactly the documents a newcomer reads first.

WHAT IT CHECKS

Every repo-relative path named in a tracked markdown file resolves — in inline
code spans, in fenced blocks, and in markdown link targets. A path is only
considered when it looks like this repository's own tree (it starts with a
directory this repo has, or names a tracked top-level file), so a URL, a
placeholder, or a path belonging to another repo is not a finding here.

VIEW

The raw file. Prose IS the target, so there is nothing to strip — a path inside a
comment in a fenced example is exactly as much a claim as one in a sentence.

PLACEHOLDERS

A segment in angle brackets or braces (`live/aws/<account>/...`) is a template,
not a path. Those are checked by resolving the literal prefix that precedes the
first placeholder, so `live/aws/<account>/us-east-1/` still proves `live/aws/`
exists without demanding a directory literally named `<account>`.

Exit 0 = every named path resolves. Exit 1 = a dangling path, or no prose read.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Inline code spans and fenced-block contents both carry paths.
CODE_SPAN = re.compile(r"`([^`\n]+)`")
LINK_TARGET = re.compile(r"\]\(([^)\s]+)\)")

# A placeholder segment. Four spellings appear in this repo's prose and all four
# mean "any value here": an angle-bracket or brace name, a shell variable, a glob,
# and a bare ellipsis standing in for elided directories. A glob is a placeholder
# wherever it appears rather than only in the last segment — `live/aws/workload-*/`
# names a family, and demanding a directory called `workload-*` is the extractor
# being wrong about the prose rather than the prose being wrong about the tree.
PLACEHOLDER = re.compile(
    r"<[^>/]*>|\{[^}/]*\}|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(\[[^\]]*\])?|\*|^\.\.\.$"
)

# Things that look like a path but are not one of ours.
NOT_OURS = re.compile(
    r"^(https?:|mailto:|#|/|~|\.\./\.\./|[A-Za-z]+://)"
    r"|^(aws|kubectl|tofu|terragrunt|git|task|python3?|bash|jq|helm|argocd)\s"
)

# A token is only a candidate path if it names this repo's own tree.
def repo_prefixes() -> tuple[set[str], set[str]]:
    tracked = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    tops = {p.split("/", 1)[0] for p in tracked if "/" in p}
    files = {p for p in tracked if "/" not in p}
    return tops, files


def candidate_paths(text: str) -> set[str]:
    found = set()
    for m in list(CODE_SPAN.finditer(text)) + list(LINK_TARGET.finditer(text)):
        tok = m.group(1).strip()
        if not tok or NOT_OURS.search(tok):
            continue
        # Strip a trailing sentence comma/period and a markdown anchor.
        tok = tok.split("#", 1)[0].rstrip(".,;:")
        if "/" not in tok and "." not in tok:
            continue
        found.add(tok)
    return found


def resolvable(tok: str, tops: set[str], files: set[str]) -> bool | None:
    """True / False if this is one of ours; None if it is not our business."""
    head = tok.split("/", 1)[0]
    if head not in tops and tok not in files:
        return None

    # Resolve up to the first placeholder segment: the literal prefix is the part
    # that is a claim, and the placeholder is by definition not one.
    literal = []
    for seg in tok.split("/"):
        if PLACEHOLDER.search(seg):
            break
        literal.append(seg)
    if not literal:
        return None

    return ROOT.joinpath(*literal).exists()


def main() -> int:
    md = [
        p for p in subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "*.md"],
            capture_output=True, text=True, check=True,
        ).stdout.split()
    ]
    if len(md) < 10:
        print(
            f"FAIL: only {len(md)} markdown file(s) found (expected >= 10). The scan "
            f"could not see the prose; refusing to report a pass.",
            file=sys.stderr,
        )
        return 1

    tops, files = repo_prefixes()
    dangling: list[str] = []
    checked = 0

    for rel in md:
        text = (ROOT / rel).read_text()
        for n, line in enumerate(text.splitlines(), 1):
            for tok in candidate_paths(line):
                verdict = resolvable(tok, tops, files)
                if verdict is None:
                    continue
                checked += 1
                if not verdict:
                    dangling.append(f"  {rel}:{n}: {tok}")

    # An empty result here would be ambiguous between "every path resolves" and
    # "nothing was recognised as a path", and this repo's prose is dense with them.
    if checked == 0:
        print(
            "FAIL: no repo-relative paths recognised in any markdown file. The "
            "extraction is broken, not the prose clean.",
            file=sys.stderr,
        )
        return 1

    if dangling:
        print("Path(s) named in prose that do not exist:\n", file=sys.stderr)
        print("\n".join(sorted(set(dangling))), file=sys.stderr)
        print(
            "\nProse that names a thing is a claim about the world. A path that no "
            "longer resolves does not break a build — it wastes the time of whoever "
            "follows it and teaches them the documentation is approximate. Fix the "
            "path, or state the requirement instead of naming a file.",
            file=sys.stderr,
        )
        return 1

    print(f"✓ every repo path named in prose resolves ({checked} reference(s) across {len(md)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
