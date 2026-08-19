#!/usr/bin/env python3
"""A Deny whose Condition can never be satisfied is not a guardrail.

IAM ANDs every key inside a single Condition block. So a Deny written as

    Condition = {
      Null = {
        "aws:RequestTag/PlatformId"         = "true"
        "aws:RequestTag/DataClassification" = "true"
      }
    }

fires only when BOTH tags are absent. A resource carrying one and missing the
other is allowed — which is the opposite of what "deny resource creation without
PlatformId and DataClassification tags" says, and that was the live description
of exactly this statement.

It was worse than a half-measure here. `live/root.hcl` injects
DataClassification into `default_tags` for every resource this repo creates, so
that key is never absent, so the AND was never satisfiable, so the statement
could not fire at all. It read as enforcement in the console and in review, and
denied nothing. Mandatory-tag enforcement wants ONE STATEMENT PER TAG.

WHAT THIS ASSERTS

A DENY statement's `Null` condition does not name multiple keys that are all
required-absent (`= "true"`). That exact shape is the footgun; split it into one
statement per key.

Two shapes are deliberately NOT flagged, because both are meaningful:
  - an ALLOW with a multi-key Null. The AWS Load Balancer Controller's reference
    policy uses it ("request tag absent AND resource tag present") and it is the
    ordinary upstream idiom.
  - a Null block with MIXED values ("true" alongside "false"). That expresses a
    real relationship between two keys rather than "all of these are missing".

An inline `# multi-key-null-ok: <reason>` waives a block that genuinely wants
"only when all of these are absent".

Exit 0 = clean. Exit 1 = a Deny that cannot fire as described, or a blind scan.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

WAIVER = re.compile(r"#\s*multi-key-null-ok:\s*\S")
# A `Null = {` block and everything up to its closing brace.
NULL_BLOCK = re.compile(r"^(?P<indent>\s*)Null\s*=\s*\{(?P<body>.*?)^(?P=indent)\}", re.S | re.M)
# A quoted condition key assignment inside that block, with its value.
KEY = re.compile(r'^\s*"(?P<key>[^"]+)"\s*=\s*"(?P<value>[^"]*)"', re.M)
# The nearest Effect above a Condition block decides whether the rule applies.
EFFECT = re.compile(r'Effect\s*=\s*"(?P<effect>Allow|Deny)"')


def scp_files() -> list[Path]:
    """Every tracked file that can carry an SCP policy body."""
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "*.tf", "*.hcl"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    keep = []
    for rel in out:
        p = ROOT / rel
        try:
            text = p.read_text()
        except (OSError, UnicodeDecodeError):
            continue
        # Only files that actually contain a Deny with a Null condition are in
        # scope; everything else has nothing to say about this rule.
        if '"Deny"' in text or "Effect = \"Deny\"" in text or "Null" in text:
            keep.append(p)
    return keep


def violations(path: Path) -> list[tuple[int, list[str]]]:
    text = path.read_text()
    lines = text.splitlines()
    found = []
    for m in NULL_BLOCK.finditer(text):
        body = m.group("body")
        pairs = KEY.findall(body)
        keys = [k for k, _ in pairs]
        if len(keys) < 2:
            continue

        # Only a DENY can be neutered this way. An Allow with a multi-key Null is
        # the ordinary upstream idiom (e.g. the AWS Load Balancer Controller's
        # "request tag absent AND resource tag present"), not a defect.
        before = EFFECT.findall(text[: m.start()])
        if not before or before[-1] != "Deny":
            continue

        # And only when every key is required-absent. Mixed values ("true" with
        # "false") express a real relationship between two keys and are meaningful;
        # all-"true" is the "deny only if ALL are missing" footgun.
        if not all(v == "true" for _, v in pairs):
            continue
        line_no = text[: m.start()].count("\n") + 1
        window = "\n".join(lines[max(0, line_no - 4) : line_no + len(keys) + 1])
        if WAIVER.search(window):
            continue
        found.append((line_no, keys))
    return found


def main() -> int:
    files = scp_files()

    # Anti-vacuity guard. If the file discovery ever stops matching, fail rather
    # than print a reassuring zero — the failure this whole class is about.
    if len(files) < 5:
        print(
            f"FAIL: only {len(files)} candidate files found (expected >= 5). The scan "
            f"could not see the tree; refusing to report a pass.",
            file=sys.stderr,
        )
        return 1

    bad = []
    for f in files:
        for line_no, keys in violations(f):
            bad.append((f.relative_to(ROOT), line_no, keys))

    if bad:
        print("Deny statement(s) whose Null condition ANDs multiple keys:\n", file=sys.stderr)
        for rel, line_no, keys in bad:
            print(f"  {rel}:{line_no}: Null names {len(keys)} keys — {', '.join(keys)}", file=sys.stderr)
        print(
            "\nIAM ANDs every key in one Condition block, so this denies only when ALL of "
            "them are absent. For mandatory-tag enforcement that is backwards: a resource "
            "carrying one and missing another is allowed. Write ONE STATEMENT PER KEY.\n"
            "If 'only when all are absent' is genuinely intended, waive it inline:\n"
            "  # multi-key-null-ok: <why>",
            file=sys.stderr,
        )
        return 1

    print(f"✓ no Deny with a multi-key Null condition ({len(files)} candidate files scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
