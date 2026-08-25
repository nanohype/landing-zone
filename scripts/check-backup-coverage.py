#!/usr/bin/env python3
"""No backup-eligible resource is silently unprotectable.

WHY THIS EXISTS

The central backup plan selects resources by tag. `aws_backup_selection` matches
on `BackupPolicy`, so a resource without that tag is not backed up — and nothing
says so. No apply fails, no drift appears, no alarm fires. The resource-tagging
standard calls this the highest-probability coverage failure precisely because it
produces no signal: the gap is discovered at the restore that does not happen.

The failure has two shapes and they need different answers.

  UNPROTECTED    the resource could carry the tag and does not.
  UNPROTECTABLE  no variable reaches it, so an operator who wants it backed up
                 has no way to ask.

The second is the one worth gating, because the first is an operator's decision
and the second is a defect in the component. This repo is a template: an operator
supplies the plan, and every data store must be reachable by that choice.

WHAT IT CHECKS

For every AWS Backup-eligible resource — the kinds in `required_on_kinds` of the
resource-tagging standard — either

  * a `BackupPolicy` tag can reach it (the tag is literal in its body, or its
    `tags` argument names a local this gate can see resolving to one), or
  * it is named in EXEMPT below with the reason it is not a backup subject.

VIEW

Comment bodies are blanked before matching. A resource's tag wiring is code, and
a comment explaining that a bucket is not backed up must not read as the wiring
that backs it up.

EXEMPTIONS ARE ASSERTED

An EXEMPT entry naming a resource that no longer exists fails the run. An
exemption that matches nothing exempts nothing today and covers something
unintended tomorrow, and it rots in the permissive direction.

Exit 0 = every eligible resource is protectable or exempt. Exit 1 = otherwise.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The resource types AWS Backup can protect, per the resource-tagging standard's
# conditional requirement. SQS, SNS, ElastiCache and MSK are deliberately absent:
# AWS Backup has no resource type for them, so tagging one is a claim the plan can
# never honour.
PROTECTABLE_RESOURCES = (
    "aws_s3_bucket",
    "aws_dynamodb_table",
    "aws_rds_cluster",
    "aws_db_instance",
    "aws_efs_file_system",
)
PROTECTABLE_MODULES = ("s3-bucket", "rds-aurora")

# Resources that are not backup subjects, each with the reason. Keyed
# "<component path>:<resource address>" so moving one forces its reason to be
# re-read rather than silently carrying over.
EXEMPT: dict[str, str] = {
    "components/aws/agent-iam/artifacts.tf:aws_s3_bucket.access_logs":
        "S3 access-log sink, unversioned. AWS Backup requires versioning on a "
        "bucket it protects, so tagging this one enrols it in a plan that then "
        "fails every job — worse than not tagging it, because the tag reads as "
        "coverage.",
    "components/aws/fleet-hub/main.tf:aws_s3_bucket.fleet_state_logs":
        "Access-log sink for the state bucket, unversioned. Same as above.",
    "components/aws/portal-hub/main.tf:aws_s3_bucket.portal_state_logs":
        "Access-log sink for the state bucket, unversioned. Same as above.",
    "components/aws/fleet-hub/main.tf:aws_s3_bucket.fleet_state":
        "OpenTofu state. Versioned, and its recovery path is the state history "
        "plus a re-import from the live account, not a point-in-time restore of "
        "the bucket. A restored older state file is actively dangerous: it "
        "describes resources that have moved on.",
    "components/aws/portal-hub/main.tf:aws_s3_bucket.portal_state":
        "OpenTofu state. Same reasoning as fleet_state.",
    "components/aws/model-import/main.tf:aws_s3_bucket.staging":
        "Staging area for open-weight model files during a Bedrock import job. "
        "Re-uploadable from the upstream model — the component header says so, "
        "and the imported model itself lives in AWS-managed storage this "
        "component does not own.",
    "components/aws/cluster-addons/s3.tf:module.loki_bucket":
        "Log storage with its own retention policy. Backing up logs that are "
        "already expiring on a schedule pays to keep what the schedule exists to "
        "delete.",
    "components/aws/cluster-addons/s3.tf:module.tempo_bucket":
        "Trace storage. Same reasoning as loki.",
    "components/aws/cluster-addons/s3.tf:module.argo_workflows_bucket":
        "Workflow run artifacts, reproducible by re-running the workflow.",
}


def blank_comment_bodies(text: str) -> str:
    """Blank comment interiors, preserving length and line breaks.

    Tag wiring is code. A comment that explains why a bucket is not backed up
    must not be able to read as the wiring that backs it up — which is exactly
    the shape this gate would otherwise agree with.
    """
    out, quote, i = [], None, 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\" and i + 1 < len(text):
                out.append(text[i : i + 2]); i += 2; continue
            if c == quote:
                quote = None
            out.append(c)
        elif c in "\"'":
            quote = c
            out.append(c)
        elif c == "#" or text[i : i + 2] == "//":
            while i < len(text) and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)


def tracked_tf() -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "*.tf"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    return [
        r for r in out
        if Path(r).parts[0] in ("components", "modules", "fleet")
        and "tests" not in Path(r).parts
    ]


def backup_locals(directory: Path) -> set[str]:
    """Local names in this directory whose value can carry a BackupPolicy tag.

    Resolved transitively to a fixed point, because the tag rarely sits one hop
    from the resource: tenant-substrate builds a per-kind map out of a data-tag
    local, so `local.datastore_tags["keyValue"]` carries the tag two references
    away from the literal. A single-hop lookup would report the best-covered
    component in the repo as unprotectable, which is the kind of false positive
    that gets a gate switched off.
    """
    # [ \t] rather than \s: \s spans newlines, so an anchored quantifier walks
    # off the end of the line and the captured name is whatever it landed on.
    ASSIGN = re.compile(
        r"^[ \t]{2,}([a-z0-9_]+)[ \t]*=[ \t]*([^\n]*(?:\n[ \t]{4,}[^\n]*)*)", re.M
    )
    values: dict[str, str] = {}
    for f in directory.glob("*.tf"):
        for m in ASSIGN.finditer(blank_comment_bodies(f.read_text())):
            values[m.group(1)] = m.group(2)

    names = {n for n, v in values.items() if "BackupPolicy" in v}
    while True:
        grown = {
            n for n, v in values.items()
            if n not in names and any(f"local.{c}" in v for c in names)
        }
        if not grown:
            return names
        names |= grown


def block_body(text: str, start: int) -> str:
    depth, i = 1, start
    while i < len(text) and depth:
        depth += (text[i] == "{") - (text[i] == "}")
        i += 1
    return text[start:i]


def main() -> int:
    files = tracked_tf()
    if len(files) < 100:
        print(
            f"FAIL: only {len(files)} .tf files found under components/modules/fleet "
            f"(expected >= 100). The scan could not see the tree; refusing to report "
            f"a pass.",
            file=sys.stderr,
        )
        return 1

    found: dict[str, bool] = {}

    for rel in files:
        path = ROOT / rel
        code = blank_comment_bodies(path.read_text())
        locals_with_tag = backup_locals(path.parent)

        def reachable(body: str) -> bool:
            if "BackupPolicy" in body:
                return True
            tags = re.search(r"^[ \t]*tags[ \t]*=[ \t]*([^\n]+)", body, re.M)
            if not tags:
                return False
            # `local.<name>` covers both the plain reference and the indexed
            # form `local.<name>["keyValue"]` that the per-kind tag maps use.
            return any(f"local.{name}" in tags.group(1) for name in locals_with_tag)

        for m in re.finditer(
            r'^resource\s+"(' + "|".join(PROTECTABLE_RESOURCES) + r')"\s+"([^"]+)"\s*\{',
            code, re.M,
        ):
            found[f"{rel}:{m.group(1)}.{m.group(2)}"] = reachable(block_body(code, m.end()))

        for m in re.finditer(r'^module\s+"([^"]+)"\s*\{', code, re.M):
            body = block_body(code, m.end())
            src = re.search(r'source\s*=\s*"([^"]+)"', body)
            if src and any(k in src.group(1) for k in PROTECTABLE_MODULES):
                found[f"{rel}:module.{m.group(1)}"] = reachable(body)

    if not found:
        print(
            "FAIL: no backup-eligible resources found in the tree. This repo "
            "provisions buckets, tables and clusters, so an empty result means the "
            "scan is blind rather than that the tree is clean.",
            file=sys.stderr,
        )
        return 1

    # An exemption that matches nothing exempts nothing today and covers
    # something unintended tomorrow.
    stale = sorted(set(EXEMPT) - set(found))
    if stale:
        print(
            "EXEMPT entr(ies) naming a resource that no longer exists:\n"
            + "".join(f"  - {k}\n" for k in stale)
            + "\nRemove the entry. An exemption describing nothing is a permission "
            "waiting for the next resource to take that address.",
            file=sys.stderr,
        )
        return 1

    unprotectable = sorted(
        addr for addr, ok in found.items() if not ok and addr not in EXEMPT
    )
    if unprotectable:
        print(
            "Backup-eligible resource(s) no BackupPolicy tag can reach:\n", file=sys.stderr
        )
        for addr in unprotectable:
            print(f"  {addr}", file=sys.stderr)
        print(
            "\nThe central plan selects on the BackupPolicy tag, so a resource no tag "
            "can reach cannot be backed up at all — an operator who wants it protected "
            "has no way to ask, and nothing anywhere reports that. Thread a "
            "backup_policy variable into its tag set (the tenant-substrate and "
            "governance components are the worked pattern), or add it to EXEMPT in "
            "this script with the reason it is not a backup subject.",
            file=sys.stderr,
        )
        return 1

    print(
        f"✓ every backup-eligible resource can carry a BackupPolicy tag "
        f"({len(found) - len(EXEMPT)} protectable, {len(EXEMPT)} exempt with a stated reason)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
