#!/usr/bin/env python3
"""Replace AWS account ids in text with a placeholder. Reads stdin, writes stdout.

WHY THIS EXISTS

drift.yml files the output of `terragrunt plan` into a GitHub issue, and this
repository is public. Since each drift leaf plans with its own account's role,
that output carries real account ids: a backend or lock error names the state
bucket `<account_id>-<region>-tfstate`, and an assume-role or access error names
the role ARN. An issue body is published the moment it is filed, so the ids are
removed before any step reads the plan output for one.

WHAT IT REPLACES

Two passes, each writing `<account-id>`:

  1. Every id in REDACT_ACCOUNT_IDS, wherever it appears, including inside a
     longer run of digits. REDACT_ACCOUNT_IDS is a JSON array of strings: the
     ids select-accounts parsed out of DRIFT_PLAN_ROLE_ARNS.
  2. Every remaining standalone run of exactly twelve digits (no digit directly
     before or after it), which is the shape of an account id. This catches an
     id that is in no role ARN — a cross-account reference, a misconfigured
     variable — at the cost of also replacing a twelve-digit number that is not
     one, which in a drift report costs nothing.

The ids arrive through the environment, never through the command line or the
script text, and pass 1 is a fixed-string replacement: an entry is used only if
it is exactly twelve ASCII digits, so no variable content can become a pattern.

Exit 0 = redacted text written. Exit 2 = REDACT_ACCOUNT_IDS is set but is not a
JSON array of strings; nothing is written, so a caller that checks the exit
status cannot publish unredacted text.
"""

from __future__ import annotations

import json
import os
import re
import sys

PLACEHOLDER = "<account-id>"
ACCOUNT_ID = re.compile(r"[0-9]{12}", re.ASCII)
STANDALONE_ACCOUNT_ID = re.compile(r"(?<![0-9])[0-9]{12}(?![0-9])", re.ASCII)


def known_ids(raw: str) -> list[str]:
    if not raw.strip():
        return []
    parsed = json.loads(raw)
    if not isinstance(parsed, list) or not all(isinstance(v, str) for v in parsed):
        raise ValueError("not a JSON array of strings")
    # Sorted, so the replacement order does not depend on the variable's key order.
    return sorted({v for v in parsed if ACCOUNT_ID.fullmatch(v)})


def redact(text: str, ids: list[str]) -> str:
    for account_id in ids:
        text = text.replace(account_id, PLACEHOLDER)
    return STANDALONE_ACCOUNT_ID.sub(PLACEHOLDER, text)


def main() -> int:
    try:
        ids = known_ids(os.environ.get("REDACT_ACCOUNT_IDS", ""))
    except ValueError as exc:  # json.JSONDecodeError is a ValueError
        print(f"REDACT_ACCOUNT_IDS is unusable ({exc}); refusing to write output", file=sys.stderr)
        return 2
    text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    sys.stdout.write(redact(text, ids))
    return 0


if __name__ == "__main__":
    sys.exit(main())
