#!/usr/bin/env python3
"""check-teardown-gates.py — every teardown gate on a component moves on one lever.

A component that can be applied and cannot be destroyed leaves a deployment you can
validate exactly once. `force_destroy_buckets` is the operator's declaration that a
substrate is disposable, honoured unconditionally in development and opt-in elsewhere.
The rule this holds is that the declaration reaches EVERY gate, not most of them.

Why a partial gate is worse than no gate. AWS spreads the protections across unrelated
resources — `force_destroy` on a bucket, `skip_final_snapshot` and `deletion_protection`
on a database, `deletion_protection_enabled` on a table — and nothing in the dependency
graph joins them, so a destroy walks them concurrently. A component whose buckets open
while its database stays protected empties the data, fails on the database, and halts
the reverse sweep above cluster and network, leaving the EKS control plane, the VPC and
the NAT gateways billing. That is strictly worse than refusing the teardown outright,
which is why the lever must reach every gate rather than most of them.

Why this is a static check and not a `tofu test`. The gate values live on resources
inside child modules — `module.tenant` -> `module.aurora` (the vendored rds-aurora
module) -> `aws_rds_cluster`. A test `assert` reaches the root module's outputs and
resources, not a grandchild's attributes, so asserting the value means re-stating the
expression in an output and comparing it to itself: a valid artifact that asserts
nothing. Reading the resource bodies is the only assertion that binds.

Four rules:

  1. POLARITY. Every teardown-gate attribute must resolve permissively when the lever is
     set. Read as polarity, not presence — `deletion_protection = local.allow_teardown`
     and `force_destroy = !local.allow_teardown` both name the lever and are armed
     exactly when a teardown is permitted.
  2. COVERAGE. Every protectable resource must actually carry the gate its type needs.
     Correct-looking gates on the resources that have them say nothing about the resource
     that has none, and an omitted gate produces the identical wedge.
  3. DECLARED POSTURE. A module holding a protectable resource without the lever, or a
     gate attribute outside the lever idiom, must be named in EXEMPT with a reason. Then
     teardown posture is a decision on the record rather than an omission.
  4. NO BLIND PASS. The check fails if it discovers no files, if a variable block never
     closes, or if an EXEMPT entry no longer describes anything. A gate whose healthy
     output is indistinguishable from its blind output is the failure it exists to catch.
"""

import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

# Attribute -> the value it must take when a teardown is permitted.
GATES = {
    "force_destroy": "true",
    "skip_final_snapshot": "true",
    "final_snapshot_identifier": "null",
    "deletion_protection": "false",
    "deletion_protection_enabled": "false",
    # Secrets Manager holds a deleted secret for a recovery window and refuses to re-mint
    # the same name until it expires, so a permitted teardown that leaves this at the
    # 30-day default succeeds and blocks the re-install it exists to enable.
    "recovery_window_in_days": "0",
    "force_delete": "true",
}

# Resource type / vendored module -> the gate it must carry. Membership means "a destroy
# of this can be refused by its own state", so it is deliberately narrow: a resource that
# always deletes cleanly does not belong here, and listing one would turn the EXEMPT table
# into a place where justifications get invented for non-problems.
#
# An empty tuple means the provider exposes no gate at all — those can only be declared in
# EXEMPT, never fixed by a flag.
PROTECTABLE = {
    "aws_s3_bucket": ("force_destroy",),
    "aws_rds_cluster": ("deletion_protection", "skip_final_snapshot"),
    "aws_db_instance": ("deletion_protection", "skip_final_snapshot"),
    "aws_dynamodb_table": ("deletion_protection_enabled",),
    # A deleted secret holds its name for the recovery window and refuses to be re-minted,
    # so a 30-day default blocks the re-install a teardown exists to enable.
    "aws_secretsmanager_secret": ("recovery_window_in_days",),
    "aws_ecr_repository": ("force_delete",),
    "aws_route53_zone": ("force_destroy",),
    # AWS refuses DeleteBackupVault while the vault holds any recovery point and the
    # provider has no force-delete, so this is the hardest wedge in the tree and the one
    # that can only ever be a declared decision.
    "aws_backup_vault": (),
    "aws_backup_vault_lock_configuration": (),
    "module:s3-bucket": ("force_destroy",),
    "module:rds-aurora": ("deletion_protection", "skip_final_snapshot"),
}

# Teardown posture declared deliberately, outside the lever idiom. Each entry is a module
# directory and why its resources must survive a teardown. Keep the reason specific — this
# table answers "can this component be torn down?", and a vague entry is how a wedge gets
# re-derived by the next reader.
EXEMPT = {
    "components/aws/cost": (
        "The CUR bucket gates force_destroy on the environment inline. Account-level "
        "billing data has no per-cluster lifecycle, so there is no substrate for a "
        "force_destroy_buckets lever to be about."
    ),
    "components/aws/backup": (
        "Recovery points are the thing that must outlive the substrate they protect, so "
        "the vault is deliberately un-forceable. A teardown that means it deletes the "
        "recovery points by hand first; that is the act, and it is not one a flag should "
        "make cheap."
    ),
    "components/aws/shared-backup": (
        "The central DR vault holds copies from every workload account and outlives all "
        "of them. Nothing a single environment's teardown does should reach it."
    ),
    "components/aws/secrets": (
        "Mints the account's CMKs and Secrets Manager entries for the platform itself, "
        "not for a tenant. Key deletion is a scheduled window by design and the secrets "
        "outlive any one cluster."
    ),
    "components/aws/fleet-hub": (
        "Crown jewels. The vend state bucket and its CMK carry prevent_destroy: they "
        "outlive every spoke they vend, so a deliberate teardown removes the guard "
        "first, by hand and on purpose. The exemption covers those two and nothing "
        "else — the access-log SINK beside them carries force_destroy, because its "
        "records are a regenerable byproduct and a non-empty log bucket otherwise "
        "wedges a teardown the operator has already deliberately authorised."
    ),
    "components/aws/portal-hub": (
        "Crown jewels, same posture as fleet-hub — the portal's workspace state bucket "
        "and CMK carry prevent_destroy and outlive the clusters they describe. Its "
        "access-log sink carries force_destroy for the same reason fleet-hub's does."
    ),
    "components/aws/org-cost": (
        "The CUR 2.0 export bucket is `org-<account>-cur-export` in the management "
        "account — one per organization, holding the billing history every cost report "
        "reads back over months. No cluster teardown should reach it."
    ),
    "components/aws/org-compliance": (
        "The CloudTrail and Config sinks are account-singleton audit evidence in the "
        "management account. They are not vended with a cluster and must survive one; "
        "destroying them is an organization decision, not a teardown step."
    ),
    "components/aws/dns": (
        "A hosted zone is the account's public identity and its delegation is held by "
        "the registrar. Deleting one on a cluster teardown takes the domain's resolution "
        "with it."
    ),
    "components/aws/private-dns": (
        "Private zones are shared across every workload in the VPC, so their lifetime is "
        "the network's, not any one cluster's."
    ),
    "components/aws/shared-dns": (
        "The shared zone lives in the network-owner account and is consumed by every "
        "spoke that associates with it."
    ),
}


def tracked_tf_files(repo):
    out = subprocess.run(
        ["git", "ls-files", "*.tf", "*.tf.json"],
        capture_output=True, text=True, check=True, cwd=repo,
    ).stdout.split()
    # Vendored provider/module trees are never authored here.
    return [
        Path(p) for p in out
        if ".terraform" not in Path(p).parts and ".terragrunt-cache" not in Path(p).parts
    ]


def code_lines(path, text):
    """(lineno, line) for lines outside any `variable "..."` block and outside heredocs.

    An object type constructor inside a variable block spells the same attribute names
    (`deletion_protection = optional(bool, true)`) and is a type expression, not a gate.
    Heredoc bodies are prose and must not be brace-counted — a single unbalanced brace in
    a description would otherwise swallow the rest of the file and silently drop every
    real gate in it.
    """
    depth, in_var, heredoc = 0, False, None
    out, unterminated = [], None
    for i, line in enumerate(text.splitlines(), 1):
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            continue
        m = re.search(r"<<-?([A-Za-z_][A-Za-z0-9_]*)\s*$", line)
        if m:
            heredoc = m.group(1)
            continue
        if not in_var and re.match(r'^variable\s+"[^"]+"\s*\{', line):
            in_var, depth, unterminated = True, line.count("{") - line.count("}"), i
            continue
        if in_var:
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                in_var, unterminated = False, None
            continue
        out.append((i, line))
    return out, unterminated


LEVER_VAR = "var.force_destroy_buckets"


def lever_locals(files):
    """Local names in this module whose value derives from the lever.

    Parsed out of `locals { ... }` blocks specifically. Matching bare `name = expr`
    anywhere would admit a resource attribute that happens to be assigned the lever, and
    then a hard-coded `locals { teardown_ok = true }` would certify a gate wired to
    nothing.
    """
    names = set()
    for f in files:
        text = f.read_text()
        for block in re.finditer(r"^locals\s*\{(.*?)^\}", text, re.S | re.M):
            body = block.group(1)
            for m in re.finditer(r"^\s{2,}([a-z0-9_]+)\s*=\s*(.+?)$", body, re.M):
                if LEVER_VAR in m.group(2):
                    names.add(m.group(1))
    return names


def lever_tokens(levers):
    return [LEVER_VAR] + [f"local.{n}" for n in sorted(levers)]


def references_lever(expr, levers):
    return any(t in expr for t in lever_tokens(levers))


def lever_is_negated(expr, levers):
    """The lever is named but its sense is flipped — armed exactly when teardown is on."""
    for t in lever_tokens(levers):
        tok = re.escape(t)
        if re.search(r"!\s*" + tok, expr):
            return True
        if re.search(tok + r"\s*==\s*false", expr) or re.search(tok + r"\s*!=\s*true", expr):
            return True
        if re.search(r"false\s*==\s*" + tok, expr):
            return True
    return False


def permissive_branch_ok(attr, expr, levers):
    """Does this expression resolve permissively when the lever is set?

    A constant equal to the permissive value is fine — it is unconditionally tearable
    down, which is more permissive than the lever, not less.
    """
    want = GATES[attr]
    expr = expr.strip()
    if expr == want:
        return True
    if not references_lever(expr, levers):
        return False
    if lever_is_negated(expr, levers):
        return False
    m = re.match(r"^(?P<cond>.+?)\s*\?\s*(?P<then>[^:?]+?)\s*:", expr)
    if m:
        return references_lever(m.group("cond"), levers) and m.group("then").strip() == want
    # A bare lever reference resolves true when the lever is set.
    return want == "true"


def declared_kinds(files):
    """Protectable resource types and vendored module calls present in this module."""
    found = defaultdict(list)
    for f in files:
        body = f.read_text()
        for key in PROTECTABLE:
            if key.startswith("module:"):
                needle = key.split(":", 1)[1]
                hit = re.search(r'^\s*source\s*=\s*"[^"]*' + re.escape(needle) + r'[^"]*"', body, re.M)
            else:
                hit = re.search(r'^resource\s+"' + re.escape(key) + r'"', body, re.M)
            if hit:
                found[key].append(f)
    return found


def main():
    repo = Path(__file__).resolve().parent.parent
    files = tracked_tf_files(repo)
    if len(files) < 50:
        print(f"::error::discovered only {len(files)} tracked .tf files — the check cannot "
              f"run from here and must not report success. Expected the landing-zone tree.")
        return 1

    by_dir = defaultdict(list)
    for rel in files:
        by_dir[rel.parent].append(repo / rel)

    failures, inventory = [], []
    exempt_seen = set()

    for d, mod_files in sorted(by_dir.items()):
        key = str(d)
        text = "".join(f.read_text() for f in mod_files)
        has_lever = f'variable "force_destroy_buckets"' in text
        levers = lever_locals(mod_files) if has_lever else set()
        if has_lever and not levers and LEVER_VAR not in text.replace(
                f'variable "force_destroy_buckets"', ""):
            failures.append(f"::error file={key}::declares force_destroy_buckets and never reads it")

        kinds = declared_kinds(mod_files)
        gates_present = defaultdict(set)

        # ── rule 1: polarity ──────────────────────────────────────────────────────────
        for f in sorted(mod_files):
            rel = f.relative_to(repo)
            lines, unterminated = code_lines(rel, f.read_text())
            if unterminated:
                failures.append(
                    f"::error file={rel},line={unterminated}::a variable block never closes, so "
                    f"the rest of this file was not scanned. Fix the braces — a partially "
                    f"scanned file reports the same green as a clean one.")
            for lineno, line in lines:
                m = re.match(r"^\s*(" + "|".join(GATES) + r")\s*=\s*(.+?)\s*$", line)
                if not m:
                    continue
                attr, expr = m.group(1), m.group(2)
                # A gate is satisfied either by the lever or by an unconditionally
                # permissive constant — managed-monitoring's `recovery_window_in_days = 0`
                # is always tearable down, which is more permissive than the lever.
                if permissive_branch_ok(attr, expr, levers):
                    gates_present[attr].add(str(rel))
                if not has_lever:
                    if not permissive_branch_ok(attr, expr, levers) and key not in EXEMPT:
                        failures.append(
                            f"::error file={rel},line={lineno}::{attr} = {expr} holds this "
                            f"resource against a teardown, in a module with no "
                            f"force_destroy_buckets and no EXEMPT entry\n"
                            f"    A gate wired to something other than the lever is the split "
                            f"posture this check exists to prevent. Give the module the lever,\n"
                            f"    set the permissive constant, or declare in EXEMPT why its data "
                            f"outlives a teardown.")
                    continue
                if not permissive_branch_ok(attr, expr, levers):
                    failures.append(
                        f"::error file={rel},line={lineno}::{attr} does not open when the "
                        f"teardown lever is set: {attr} = {expr}\n"
                        f"    Spell the permissive branch out so the polarity is readable:\n"
                        f"      {attr} = <lever> ? {GATES[attr]} : <the leaf's own pin>")

        # ── rule 2: coverage — every protectable resource carries its gate ────────────
        ungated = {}
        for kind in sorted(kinds):
            missing = [g for g in PROTECTABLE[kind] if g not in gates_present]
            if missing or not PROTECTABLE[kind]:
                ungated[kind] = missing

        n_gates = sum(len(v) for v in gates_present.values())

        if key in EXEMPT:
            exempt_seen.add(key)
            if kinds:
                inventory.append(f"  {key}: EXEMPT ({', '.join(sorted(kinds))})")
            continue

        if not kinds:
            if has_lever:
                inventory.append(f"  {key}: lever, {n_gates} gate(s)")
            continue

        for kind, missing in sorted(ungated.items()):
            if missing:
                failures.append(
                    f"::error file={key}::{kind} carries no {', '.join(missing)}\n"
                    f"    Correct gates on the resources that have them say nothing about the "
                    f"resource that has none. An omitted gate wedges the destroy exactly like\n"
                    f"    one wired backwards, and the reverse sweep halts above cluster and "
                    f"network either way.")
            else:
                failures.append(
                    f"::error file={key}::{kind} has no teardown gate the provider exposes, so "
                    f"this module cannot be destroyed by a flag\n"
                    f"    Declare it in EXEMPT with the reason its data outlives a teardown, and "
                    f"say what the manual act is.")

        # ── rule 3: declared posture ──────────────────────────────────────────────────
        if not has_lever and not ungated:
            inventory.append(f"  {key}: no lever, {n_gates} permissive constant(s) "
                             f"({', '.join(sorted(kinds))})")
        elif has_lever:
            inventory.append(f"  {key}: lever, {n_gates} gate(s), {', '.join(sorted(kinds))}")

    # ── rule 4: no blind pass ─────────────────────────────────────────────────────────
    for key in sorted(set(EXEMPT) - exempt_seen):
        failures.append(
            f"::error file={key}::EXEMPT entry describes nothing — the directory is gone, or no "
            f"longer holds a protectable resource.\n"
            f"    A stale exemption is a teardown decision nobody is making any more.")

    print("Teardown posture by module:")
    for line in inventory:
        print(line)
    print(f"\n{len(files)} tracked .tf files scanned.\n")

    if failures:
        for f in failures:
            print(f)
        print(f"\n{len(failures)} teardown-gate problem(s).")
        return 1

    # The scope belongs in the assertion, not two lines above it. A reader who
    # sees the claim sees what it ranged over, and cannot read one without the
    # other.
    print(
        f"Every teardown gate opens on the lever, every protectable resource carries "
        f"one, and every module without one declares why — {len(inventory)} module(s) "
        f"across {len(files)} tracked .tf files."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
