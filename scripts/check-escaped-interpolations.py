#!/usr/bin/env python3
"""An escaped interpolation must be one somebody meant to write.

`$${` is HCL's escape for a literal `${`, and `%%{` is the same for `%{`. Both
are legitimate — an IAM policy that passes `${aws:username}` through to AWS, a
user_data script with a shell variable — but both are also what a reference
looks like when the escape was not intended. The two cases are indistinguishable
to every other gate this repo runs:

  values = ["user:Environment$${var.environment}"]

renders as the 34-character string `user:Environment${var.environment}`. It is
valid HCL, `tofu fmt` accepts it, `tofu validate` accepts it, tflint accepts it,
checkov accepts it, and the plan is clean. Applied, it becomes an AWS Budgets
cost filter matching a tag value no resource carries — a budget whose actual and
forecast are $0 forever, whose thresholds cannot breach, and which shows green.
The control exists and is wired to nothing.

So the escape is not banned; it is made deliberate. Every occurrence is either
removed or listed in EXEMPT with the reason it has to reach the provider as
text. That is the same contract `.checkov.yaml` states for its skips: if an
exemption loses its rationale, delete the exemption and let CI fail until the
finding is fixed.
"""

from __future__ import annotations

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# HCL's two template escapes. `$${` produces a literal `${`; `%%{` produces `%{`.
ESCAPE = re.compile(r"\$\$\{|%%\{")

# A whole-line comment. HCL does not interpolate comments, so an escape inside
# one is not an escape — it is prose about escapes, which any file explaining
# this defect will contain. Only whole-line comments are skipped: a trailing
# comment on a code line is left in scope, because deciding whether a `#` opens
# a comment or sits inside a string needs a parser, and over-reporting there is
# the safe direction.
COMMENT = re.compile(r"^\s*(#|//)")

# Occurrences that must reach the provider as text, each with the reason it
# does. Keyed by "<path>:<line>" so moving the line forces the reason to be
# re-read rather than silently carrying over.
#
# Empty is the correct state. An entry here is a claim that some downstream
# system — not OpenTofu — resolves the expression.
EXEMPT: dict[str, str] = {}


def tracked_hcl() -> list[pathlib.Path]:
    """Every tracked .tf and .hcl file. Tracked, so a vendored .terraform or
    .terragrunt-cache tree cannot contribute findings or mask them."""
    out = subprocess.run(
        ["git", "ls-files", "-z", "*.tf", "*.hcl"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [ROOT / p for p in out.split("\0") if p]


def main() -> int:
    files = tracked_hcl()
    if not files:
        print("FAIL  git ls-files matched no .tf or .hcl files — this check would")
        print("      pass vacuously. The invocation path or the tree layout moved.")
        return 1

    findings: list[tuple[str, str]] = []
    exempted: set[str] = set()

    for path in files:
        rel = path.relative_to(ROOT).as_posix()
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if COMMENT.match(line) or not ESCAPE.search(line):
                continue
            key = f"{rel}:{lineno}"
            if key in EXEMPT:
                exempted.add(key)
                continue
            findings.append((key, line.strip()))

    stale = sorted(set(EXEMPT) - exempted)
    for key in stale:
        print(f"FAIL  {key} is exempted and has no escaped interpolation.")
        print("      The line moved or the escape is gone. Delete the exemption.")

    for key, text in findings:
        print(f"FAIL  {key} escapes an interpolation, so it renders as text:")
        print(f"          {text}")
        print("      If that is intended, add it to EXEMPT with the reason the")
        print("      expression has to reach the provider unresolved. If it is not,")
        print("      build the string with format() so the reference resolves.")

    if findings or stale:
        print()
        print(f"{len(findings)} unexplained escape(s), {len(stale)} stale exemption(s).")
        return 1

    scanned = len(files)
    print(f"escaped interpolations ok — {scanned} tracked HCL files, "
          f"{len(EXEMPT)} explained exemption(s), no unexplained escapes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
