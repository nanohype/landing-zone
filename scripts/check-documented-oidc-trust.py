#!/usr/bin/env python3
"""Documentation must not describe a GitHub OIDC trust the component refuses to ship.

`components/aws/github-oidc` builds each trusted subject as
`repo:<org>/<repo>:<claim>`, and its `allowed_subject_claims` default excludes a
bare `*` deliberately. The variable's own description gives the reason: a bare
`:*` also trusts `pull_request` and every branch context, so on a public
repository a fork's pull request could assume the role.

A documented trust policy wider than the shipped one is not a documentation
defect with a documentation cost. Two surfaces make it a security one:

  - the threat model lists the trust scoping as the MITIGATION for "a foreign
    workflow assuming the deploy role". A wildcard claim suffix is what enables
    that, so the document a security reviewer opens first would state the
    vulnerability as the control.
  - the troubleshooting guide shows a trust policy an operator is told to match,
    inside a procedure for debugging OIDC failures. A reader following it widens
    a live role to whatever the document shows.

Neither surface is reached by the checks that read component internals, and
nothing else compares prose against the component's own defaults.

WHAT THIS ASSERTS

Wherever prose shows a `token.actions.githubusercontent.com:sub` value, or names
a `repo:<org>/<repo>:...` subject, the claim suffix is one the component can
actually emit — never a bare `*`. The permitted suffixes are read from
`allowed_subject_claims` and `plan_allowed_subject_claims` in the component's
own `variables.tf`, so widening the component widens what may be documented, and
the two cannot drift apart in the direction that matters.

A bare `:*` is rejected even if someone adds it to the defaults, because the
documentation claim this protects is that the estate does not trust one.

A LIMITATION, stated because it constrains how the docs may be written: this
cannot distinguish use from mention. Prose that quotes a bare `:*` in order to
warn against it is indistinguishable from prose asserting it, so the rule is that
documentation DESCRIBES the anti-pattern rather than reproducing the string —
"a wildcard claim suffix" rather than the literal. That is a real cost, and it
buys a check that cannot be talked past.

Exit 0 = clean. Exit 1 = a documented subject the component would not emit, or a
scan that could not see its inputs.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMPONENT_VARS = ROOT / "components" / "aws" / "github-oidc" / "variables.tf"

# `repo:<something>/<something>:<claim>` wherever it appears in prose.
SUBJECT = re.compile(r"repo:[^\s`\"']+/[^\s`\"':]+:(?P<claim>[^\s`\"',\]]+)")
# A default list on either claims variable.
DEFAULT_LIST = re.compile(
    r'variable\s+"(?:allowed_subject_claims|plan_allowed_subject_claims)".*?default\s*=\s*\[(?P<body>[^\]]*)\]',
    re.S,
)
QUOTED = re.compile(r'"([^"]+)"')


def permitted_claims() -> set[str]:
    """Claim suffixes the component can emit, read from the component itself."""
    text = COMPONENT_VARS.read_text()
    claims: set[str] = set()
    for m in DEFAULT_LIST.finditer(text):
        claims |= set(QUOTED.findall(m.group("body")))
    return claims


def claim_permitted(claim: str, permitted: set[str]) -> bool:
    if claim == "*":
        return False  # never documentable, whatever the defaults say
    for p in permitted:
        if p.endswith("*") and claim.startswith(p[:-1]):
            return True
        if claim == p:
            return True
    return False


def prose_files() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "*.md", "*.yml", "*.yaml"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [ROOT / rel for rel in out]


def main() -> int:
    if not COMPONENT_VARS.is_file():
        print(f"::error::{COMPONENT_VARS} is missing — this check reads the permitted claims from it")
        return 1

    permitted = permitted_claims()
    files = prose_files()

    # Anti-vacuity on BOTH inputs. Zero permitted claims means the parse failed,
    # and would make every documented subject look unpermitted; zero files means
    # the scan saw nothing and would pass over everything.
    if len(permitted) < 2 or len(files) < 10:
        print(
            f"::error::parsed {len(permitted)} permitted claim(s) from the component and "
            f"discovered {len(files)} prose file(s) (expected at least 2 and 10). The scan "
            f"did not see its inputs and refuses to report a pass."
        )
        return 1

    bad: list[tuple[str, int, str]] = []
    for f in files:
        try:
            lines = f.read_text().splitlines()
        except (OSError, UnicodeDecodeError):
            continue
        for n, line in enumerate(lines, 1):
            for m in SUBJECT.finditer(line):
                claim = m.group("claim")
                if not claim_permitted(claim, permitted):
                    bad.append((f.relative_to(ROOT).as_posix(), n, claim))

    if bad:
        print("Documented OIDC subject(s) the component would not emit:\n", file=sys.stderr)
        for rel, n, claim in bad:
            print(f"  {rel}:{n}: claim suffix ':{claim}'", file=sys.stderr)
        print(
            f"\nPermitted suffixes, read from components/aws/github-oidc/variables.tf: "
            f"{', '.join(sorted(permitted))}\n"
            "A bare ':*' is never documentable: it trusts pull_request and every branch, so "
            "on a public repository a fork's pull request could assume the role. Documentation "
            "showing it teaches an operator to widen their trust policy to exactly the claim "
            "the component refuses to ship.",
            file=sys.stderr,
        )
        return 1

    print(
        f"✓ every documented OIDC subject uses a claim the component emits "
        f"({len(files)} prose files scanned, {len(permitted)} permitted suffixes)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
