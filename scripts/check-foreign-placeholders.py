#!/usr/bin/env python3
"""A leaf that applies today must not name an account that does not exist.

WHY THIS EXISTS

Every account id in this tree is a placeholder — `live/aws/*/account.hcl` holds
111111111111, 222222222222, 333333333333 and friends, and that is correct for a
public repo. `root.hcl` resolves a leaf's OWN account from
`TERRAGRUNT_ACCOUNT_ID`, so the placeholder never reaches AWS.

The asymmetry is the defect. A FOREIGN account id — one leaf naming a different
account — has no injection path at all. There is one `TERRAGRUNT_ACCOUNT_ID`,
and it cannot express "and the backup account is X". So a foreign placeholder is
not a stand-in that gets replaced at deploy time; it is a literal that reaches
AWS.

Two instances, both on leaves that apply today:

  * every workload backup plan composed a copy_action to a vault in
    666666666666, an account not in the organization. Cross-account copy needs
    all three of both accounts in one org, the destination vault existing with a
    CopyIntoBackupVault policy, and the feature enabled from the management
    account — none of which can be true of an account that does not exist.
  * every break-glass leaf trusted 123456789012 on an AdministratorAccess role.
    A break-glass role assumable by nobody, discovered during the emergency it
    exists for.

WHAT IT CHECKS

For every live leaf under an account whose own id IS environment-injectable —
i.e. one that can be applied today — no rendered input may carry a placeholder
account id belonging to a DIFFERENT account catalog.

Leaves under accounts that are themselves unprovisioned (network, management,
backup, fleet, reference-adopt) are out of scope by construction: the whole leaf
is unappliable until that account exists, which is honest. This is about the
ones that apply now.

Deliberately textual over the live tree rather than a terragrunt render. The
render already happens in the `evaluate` CI job and needs terragrunt plus mock
resolution; this needs to run anywhere, and a foreign id is a literal in the
file by definition — if it were resolved from somewhere it would not be one.

    scripts/check-foreign-placeholders.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIVE = ROOT / "live" / "aws"

# Accounts whose leaves are appliable today: their own id resolves from
# TERRAGRUNT_ACCOUNT_ID, so the leaf reaches a real account.
APPLIABLE = re.compile(r"^workload-[a-z]+$")

ACCOUNT_ID = re.compile(r"\b(\d{12})\b")

# An id is "foreign" to a leaf when it is the placeholder of a DIFFERENT account
# catalog. Built from the tree rather than hardcoded, so a new account directory
# is covered without editing this file.
def account_catalog() -> dict[str, str]:
    out: dict[str, str] = {}
    for hcl in sorted(LIVE.glob("*/account.hcl")):
        m = re.search(r'account_id\s*=\s*"(\d{12})"', hcl.read_text(encoding="utf-8"))
        if m:
            out[hcl.parent.name] = m.group(1)
    return out


def main() -> int:
    if not LIVE.is_dir():
        print(f"FAIL  {LIVE} does not exist")
        return 1

    catalog = account_catalog()
    if not catalog:
        print(f"FAIL  no account.hcl under {LIVE.relative_to(ROOT)} declares an account_id —")
        print("      the parse matched nothing, so this check is asserting nothing.")
        return 1

    appliable = {a for a in catalog if APPLIABLE.match(a)}
    if not appliable:
        print("FAIL  no account directory matches the appliable pattern, so this check")
        print("      would pass having examined no leaf at all.")
        return 1

    ok = True
    scanned = 0
    for account in sorted(appliable):
        own = catalog[account]
        foreign = {v: k for k, v in catalog.items() if v != own}
        for leaf in sorted((LIVE / account).rglob("terragrunt.hcl")):
            if ".terragrunt-cache" in leaf.parts:
                continue
            scanned += 1
            text = leaf.read_text(encoding="utf-8")
            for i, line in enumerate(text.splitlines(), 1):
                stripped = line.strip()
                if stripped.startswith("#"):
                    continue
                for found in ACCOUNT_ID.findall(line):
                    if found not in foreign:
                        continue
                    ok = False
                    rel = leaf.relative_to(ROOT)
                    print(f"FAIL  {rel}:{i}")
                    print(f"      names {found}, the placeholder for the "
                          f"{foreign[found]!r} account, which is not provisioned.")
                    print("      This leaf applies today, and a foreign account id has no")
                    print("      injection path — TERRAGRUNT_ACCOUNT_ID resolves only the")
                    print("      leaf's OWN account — so this literal reaches AWS as written.")

    if scanned == 0:
        print("FAIL  found no live leaf under the appliable accounts, so this check")
        print("      examined nothing.")
        return 1

    if ok:
        print(f"✓ no appliable leaf names a foreign placeholder account "
              f"({scanned} leaves under {', '.join(sorted(appliable))})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
