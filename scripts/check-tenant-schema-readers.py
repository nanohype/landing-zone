#!/usr/bin/env python3
"""check-tenant-schema-readers.py — every field a tenant can declare must reach a resource.

The multi-tenant components take a `tenants` map whose object type is the contract a leaf
writes against. A field in that type with no reader is not inert: it is a control an
operator can set, sees accepted, and believes is in force.

`object_lock_enabled = true` in a production governance leaf is the sharp version. It
reads as an S3 Object Lock on the tenant's audit archive — the one protection a
force_destroy cannot override — from the schema, from the leaf, and from the operations
doc. Nothing implements it. An operator answering "is the audit archive immutable?" from
the configuration gets `true`, and the answer is no.

It is also the same shape as a dead allow-rule or a grant on an unencryptable bucket: an
artifact that is valid, that every gate accepts, and that delivers nothing. Those are
caught by reading both ends together, which is what this does — the declared field on one
side, a resource that consumes it on the other.

The rule: for every component with a `tenants` (or `tenant_config`) object type, each
attribute must be referenced somewhere in that component's own `.tf` outside the type
declarations. Fields that are deliberately consumed only by a name or a validation belong
in ALLOW below with the reason.
"""

import re
import subprocess
import sys
from pathlib import Path

# Attributes that legitimately have no resource reader, and why.
ALLOW = {}


def tracked(repo, *globs):
    out = subprocess.run(
        ["git", "ls-files", *globs], capture_output=True, text=True, check=True, cwd=repo
    ).stdout.split()
    return [Path(p) for p in out if ".terraform" not in Path(p).parts]


def object_type_fields(text, var_names):
    """Attribute names declared inside `variable "<name>" { type = ... object({...}) }`."""
    fields = {}
    for var in var_names:
        m = re.search(r'^variable\s+"' + var + r'"\s*\{(.*?)^\}', text, re.S | re.M)
        if not m:
            continue
        for fm in re.finditer(r"^\s{4,}([a-z0-9_]+)\s*=\s*(optional\(|bool|number|string|list|map|object)",
                              m.group(1), re.M):
            fields.setdefault(fm.group(1), var)
    return fields


def main():
    repo = Path(__file__).resolve().parent.parent
    components = sorted({p.parent for p in tracked(repo, "components/**/variables.tf")})
    failures, checked = [], 0

    for comp in components:
        vfile = repo / comp / "variables.tf"
        if not vfile.exists():
            continue
        vtext = vfile.read_text()
        fields = object_type_fields(vtext, ("tenants", "tenant_config"))
        if not fields:
            continue
        checked += 1

        # Everything this module and its own sub-modules can read.
        bodies = []
        for f in sorted((repo / comp).rglob("*.tf")):
            if ".terraform" in f.parts:
                continue
            bodies.append((f, f.read_text()))

        for field, owner in sorted(fields.items()):
            if field in ALLOW:
                continue
            readers = []
            for f, body in bodies:
                # Strip variable blocks so a declaration is never its own reader.
                stripped = re.sub(r'^variable\s+"[^"]+"\s*\{.*?^\}', "", body, flags=re.S | re.M)
                if re.search(r"[.\[]" + re.escape(field) + r"\b", stripped) or \
                   re.search(r'"' + re.escape(field) + r'"', stripped):
                    readers.append(f)
            if not readers:
                rel = (comp / "variables.tf").as_posix()
                failures.append(
                    f"::error file={rel}::`{field}` is declared on {comp.name}'s `{owner}` type "
                    f"and read by no resource in the component\n"
                    f"    A tenant field with no reader is a control an operator can set, sees\n"
                    f"    accepted, and believes is in force. Implement it, delete it from the\n"
                    f"    type and every live leaf, or add it to ALLOW in this script with the\n"
                    f"    reason it has no reader.")

    # Anti-vacuity. This check reports an invariant over whatever it discovered,
    # so a discovery that finds nothing reports the invariant holding over
    # nothing — printing "Checked tenant schemas in 0 component(s)" directly
    # above "Every tenant-declarable field reaches a resource", exit 0. The count
    # was already on screen and nothing read it.
    #
    # Any of these produce that: a `git ls-files` that matches nothing because
    # the check ran outside the repository, a components/ directory that moved,
    # or a rename of the `tenants` variable that makes every schema invisible to
    # the parser. None of them is a state where this repository is healthy, and
    # all of them look identical to a clean run.
    #
    # The floor is deliberately below the real count rather than equal to it:
    # this asserts that discovery WORKED, and a component legitimately gaining or
    # losing a tenants schema must not require editing this number.
    MIN_COMPONENTS = 3
    if checked < MIN_COMPONENTS:
        print(
            f"::error::discovered tenant schemas in only {checked} component(s) "
            f"(expected at least {MIN_COMPONENTS}). The scan did not see the tree, "
            f"so this check has nothing to report on and refuses to report a pass."
        )
        return 1

    print(f"Checked tenant schemas in {checked} component(s).\n")
    if failures:
        for f in failures:
            print(f)
        print(f"\n{len(failures)} tenant field(s) declared but never read.")
        return 1
    # Scope inside the assertion, not two lines above it — a separated count is
    # exactly what let this check print "0 component(s)" over a clean-looking pass.
    print(f"Every tenant-declarable field reaches a resource — {checked} component(s) checked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
