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

  1. Every id in DRIFT_PLAN_ROLE_ARNS, wherever it appears, including inside a
     longer run of digits. DRIFT_PLAN_ROLE_ARNS is the drift GitHub
     Environment's secret mapping each account directory to its plan role ARN;
     an id is every run of twelve digits in its raw text (a longer run is read
     as consecutive twelve-digit chunks), keys and values alike and whether or
     not it parses as JSON, so an id in an entry drift.yml left out is redacted
     too.
  2. Every remaining standalone run of exactly twelve digits (no digit directly
     before or after it), which is the shape of an account id. This catches an
     id that is in no role ARN — a cross-account reference, a misconfigured
     variable — at the cost of also replacing a twelve-digit number that is not
     one, which in a drift report costs nothing.

The ids arrive through the environment, never through the command line or the
script text, and pass 1 is a fixed-string replacement of runs of twelve ASCII
digits, so no secret content can become a pattern. The Actions logs are masked
separately (drift.yml registers every id and role ARN with ::add-mask:: before
anything prints); this script is what keeps the ids out of the issues, which
the runner's masking never reaches.

USAGE

  redact-account-ids.py                 pass 1 with whatever DRIFT_PLAN_ROLE_ARNS
                                        holds (unset or empty: pass 2 only)
  redact-account-ids.py --require-ids   as above, but DRIFT_PLAN_ROLE_ARNS must
                                        hold at least one id. drift.yml calls it
                                        this way for plan output: a leaf is only
                                        planned with a role ARN from the secret,
                                        so no id means the secret did not arrive,
                                        and pass 2 alone would miss an id run
                                        together with other digits
  redact-account-ids.py --self-test     run the built-in cases (synthetic ids
                                        only) and exit; reads no stdin

Exit 0 = redacted text written (or the self-test passed). Exit 2 =
--require-ids found no id in DRIFT_PLAN_ROLE_ARNS, or an unknown argument;
nothing is written, so a caller that checks the exit status cannot publish
unredacted text. Exit 1 = a self-test case failed.
"""

from __future__ import annotations

import contextlib
import io
import os
import re
import sys

PLACEHOLDER = "<account-id>"
ACCOUNT_ID = re.compile(r"[0-9]{12}", re.ASCII)
STANDALONE_ACCOUNT_ID = re.compile(r"(?<![0-9])[0-9]{12}(?![0-9])", re.ASCII)


def known_ids(raw: str) -> list[str]:
    """Every twelve-digit run in the role map's raw text, sorted and unique.

    The raw text, not a parse of it: a value drift.yml rejects (a malformed ARN, a
    key that is an id) still carries an id that can surface in plan output.
    Sorted, so the replacement order does not depend on the secret's key order.
    """
    return sorted(set(ACCOUNT_ID.findall(raw)))


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

    role_map = f'{{"workload-staging":"arn:aws:iam::{b}:role/github-actions-plan","network":"arn:aws:iam::{a}:role/github-actions-plan"}}'
    ids = known_ids(role_map)
    expect("ids read from the role map, sorted", ids, [a, b])
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
    # Ids in entries drift.yml rejects are still ids: a key that is an id, a value
    # that is not a role ARN, and text that is not JSON at all.
    expect(
        "ids in rejected entries and non-JSON text",
        known_ids(f'{{"{a}":"not-an-arn {b}"}}'),
        [a, b],
    )
    expect("non-JSON text", known_ids(f"garbage {a} more"), [a])
    expect("a run of 24 digits is two ids", known_ids(a + b), [a, b])
    # No content of the secret becomes a pattern: only digit runs are taken.
    expect("metacharacters and short runs are ignored", known_ids('{".*":"[0-9]+ 1234"}'), [])
    expect("ignored entry changes nothing", redact("plain text", known_ids('{".*":"x"}')), "plain text")
    expect("empty secret", known_ids(""), [])

    # Fail closed: with --require-ids, a secret that is unset, empty or holds no
    # id refuses (exit 2) before reading stdin, so nothing is written.
    saved = os.environ.pop("DRIFT_PLAN_ROLE_ARNS", None)
    try:
        for label, raw in (("unset", None), ("empty", ""), ("no id", '{"workload-staging":"not-an-arn"}')):
            if raw is not None:
                os.environ["DRIFT_PLAN_ROLE_ARNS"] = raw
            with contextlib.redirect_stderr(io.StringIO()):
                code = main(["--require-ids"])
            expect(f"--require-ids refuses a secret that is {label}", code, 2)
    finally:
        os.environ.pop("DRIFT_PLAN_ROLE_ARNS", None)
        if saved is not None:
            os.environ["DRIFT_PLAN_ROLE_ARNS"] = saved

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
    ids = known_ids(os.environ.get("DRIFT_PLAN_ROLE_ARNS", ""))
    if "--require-ids" in args and not ids:
        print("DRIFT_PLAN_ROLE_ARNS holds no account id and --require-ids is set; refusing to write output", file=sys.stderr)
        return 2
    text = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    sys.stdout.write(redact(text, ids))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
