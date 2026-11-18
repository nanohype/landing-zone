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

USAGE

  redact-account-ids.py                 pass 1 with whatever REDACT_ACCOUNT_IDS
                                        holds (unset or empty: pass 2 only)
  redact-account-ids.py --require-ids   as above, but REDACT_ACCOUNT_IDS must be
                                        set and name at least one id. drift.yml
                                        calls it this way for plan output: by
                                        then select-accounts has always found an
                                        id, so an empty list means the id list
                                        did not arrive, and pass 2 alone would
                                        miss an id run together with other digits
  redact-account-ids.py --self-test     run the built-in cases (synthetic ids
                                        only) and exit; reads no stdin

Exit 0 = redacted text written (or the self-test passed). Exit 2 =
REDACT_ACCOUNT_IDS is not a JSON array of strings, or --require-ids found no id
in it; nothing is written, so a caller that checks the exit status cannot
publish unredacted text. Exit 1 = a self-test case failed.
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


def self_test() -> int:
    """The behaviour drift.yml relies on, against synthetic ids only.

    Run in CI (the `workflows` job) so a later edit to this file that weakens a
    pass fails a pull request, and by drift.yml before it redacts, so a broken
    redactor fails the job before anything is filed.
    """
    a, b = "111122223333", "444455556666"
    failures: list[str] = []

    def expect(name: str, got: object, want: object) -> None:
        if got != want:
            failures.append(f"{name}: got {got!r}, want {want!r}")

    ids = known_ids(json.dumps([a, b]))
    expect("known ids parsed and sorted", ids, [a, b])
    expect(
        "state bucket and role ARN",
        redact(f"bucket {a}-us-east-1-tfstate role arn:aws:iam::{b}:role/x", ids),
        f"bucket {PLACEHOLDER}-us-east-1-tfstate role arn:aws:iam::{PLACEHOLDER}:role/x",
    )
    expect("known id inside a longer digit run", redact(f"9{a}9", ids), f"9{PLACEHOLDER}9")
    expect("two known ids run together", redact(a + b, ids), PLACEHOLDER * 2)
    expect("unknown standalone id (pattern pass)", redact("x 999988887777 y", []), f"x {PLACEHOLDER} y")
    expect("unknown id inside a longer run is left alone", redact("1234567890123", []), "1234567890123")
    expect("eleven digits are left alone", redact("12345678901", []), "12345678901")
    # An entry that is not exactly twelve digits never becomes a pattern or a
    # replacement: a regex metacharacter entry must not match arbitrary text.
    expect(
        "metacharacter and short entries are ignored",
        known_ids(json.dumps([".*", "[0-9]+", "1234", a])),
        [a],
    )
    expect("ignored entry changes nothing", redact("plain text", known_ids(json.dumps([".*"]))), "plain text")
    expect("empty list", known_ids(""), [])
    for bad in ('{"k":"v"}', "[1, 2]", "not json"):
        try:
            known_ids(bad)
        except ValueError:
            continue
        failures.append(f"malformed list {bad!r} was accepted")

    for line in failures:
        print(f"redact-account-ids self-test FAILED: {line}", file=sys.stderr)
    if failures:
        return 1
    print("redact-account-ids self-test passed.")
    return 0


def main(argv: list[str]) -> int:
    args = set(argv)
    unknown = args - {"--require-ids", "--self-test"}
    if unknown:
        print(f"unknown argument(s): {' '.join(sorted(unknown))}", file=sys.stderr)
        return 2
    if "--self-test" in args:
        return self_test()
    try:
        ids = known_ids(os.environ.get("REDACT_ACCOUNT_IDS", ""))
    except ValueError as exc:  # json.JSONDecodeError is a ValueError
        print(f"REDACT_ACCOUNT_IDS is unusable ({exc}); refusing to write output", file=sys.stderr)
        return 2
    if "--require-ids" in args and not ids:
        print("REDACT_ACCOUNT_IDS names no account id and --require-ids is set; refusing to write output", file=sys.stderr)
        return 2
    text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    sys.stdout.write(redact(text, ids))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
