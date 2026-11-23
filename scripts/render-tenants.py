#!/usr/bin/env python3
"""Render a Platform CR's spec.datastores into tenant-substrate's var.tenants.

WHY THIS EXISTS

A tenant declares its stateful substrate once, in its Platform CR. Two consumers
read that declaration: the eks-agent-platform operator, which generates the
scoped IAM policy reaching each store, and landing-zone's tenant-substrate
module, which provisions the store itself. The operator reads the CR directly.
Nothing carried it to the module — `var.tenants` was `{}` in every environment,
so a tenant that declared datastores got IAM grants on ARNs that named nothing,
and the failure was silence: the apply succeeded with no work to do.

This is that missing step. It is a renderer, not a translator with opinions:
every value in the output comes from a CR or from a default both schemas already
agree on. The two schemas differ only in case convention — the CR is camelCase
because it is Kubernetes, the variable is snake_case because it is Terraform —
so the mapping is mechanical and is asserted as such below.

WHAT SELECTS A TENANT

`var.tenants` is per-environment; a Platform CR carries no environment. That is
not an omission in the CR — the same CR is applied to whichever cluster runs the
app, so "which environments run this tenant" is a fleet fact, not an app fact.
So each environment's leaf carries a `tenants.selection.yaml` naming the tenants
it provisions substrate for, and this script resolves each name to that tenant's
Platform CR. Adding a tenant to an environment is one line in the selection;
what that tenant *gets* is never written here.

THE GENERATED FILE IS COMMITTED

`tenants.generated.json` lands next to the selection and the leaf reads it. It is
committed so a plan is reproducible without network access to four other repos,
and `--check` re-renders and diffs so a CR that changes without a re-render fails
CI rather than drifting quietly.

    scripts/render-tenants.py --environment development
    scripts/render-tenants.py --environment development --check
    scripts/render-tenants.py --self-test

`--self-test` renders synthetic Platform CRs in a scratch tree: every datastore
kind and mapped field, each schema divergence and malformed selection refused,
and `--check` on a fresh, a stale and a missing rendering.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import pathlib
import sys
import tempfile
from unittest import mock

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML required: pip install pyyaml")

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIVE = ROOT / "live" / "aws"

# The CR is camelCase, the Terraform variable is snake_case, and that is the
# whole of the difference. Keyed by the datastore kind, then by CR field name.
#
# A kind absent from this table has no config block on either side (`stream`),
# and a field absent from a kind's map is a field one schema has and the other
# does not — which the parity assertion below refuses to let happen silently.
FIELD_MAP: dict[str, dict[str, str]] = {
    "relational": {
        "engineVersion": "engine_version",
        "minACU": "min_acu",
        "maxACU": "max_acu",
        "backupRetentionDays": "backup_retention_days",
        "deletionProtection": "deletion_protection",
    },
    "keyValue": {
        "partitionKey": "partition_key",
        "sortKey": "sort_key",
        "billingMode": "billing_mode",
        "ttlAttribute": "ttl_attribute",
        "pointInTimeRecovery": "point_in_time_recovery",
        "globalSecondaryIndexes": "global_secondary_indexes",
    },
    "objectStore": {
        "versioning": "versioning",
        "lifecycleExpireDays": "lifecycle_expire_days",
    },
    "queue": {
        "fifo": "fifo",
        "visibilityTimeoutSeconds": "visibility_timeout_seconds",
        "messageRetentionSeconds": "message_retention_seconds",
        "maxReceiveCount": "max_receive_count",
    },
    "cache": {
        "engine": "engine",
        "nodeType": "node_type",
        "replicas": "replicas",
    },
}

# The block key itself also changes case.
BLOCK_KEY = {
    "relational": "relational",
    "keyValue": "key_value",
    "objectStore": "object_store",
    "queue": "queue",
    "cache": "cache",
}

# Nested objects inside keyValue carry their own camelCase.
NESTED_KEY_MAP = {
    "partitionKey": {"name": "name", "type": "type"},
    "sortKey": {"name": "name", "type": "type"},
    "globalSecondaryIndexes": {
        "name": "name",
        "partitionKey": "partition_key",
        "sortKey": "sort_key",
        "projection": "projection",
    },
}


def convert_gsi(gsi: dict) -> dict:
    out: dict = {}
    for k, v in gsi.items():
        mapped = NESTED_KEY_MAP["globalSecondaryIndexes"].get(k)
        if mapped is None:
            raise ValueError(f"globalSecondaryIndexes carries unmapped field {k!r}")
        out[mapped] = v
    return out


def convert_datastore(ds: dict, where: str) -> dict:
    kind = ds["kind"]
    out: dict = {"name": ds["name"], "kind": kind}
    if "deletionPolicy" in ds:
        out["deletion_policy"] = ds["deletionPolicy"]

    if kind not in BLOCK_KEY:
        # `stream` carries no config block on either side. A block appearing here
        # means the CRD grew one and this renderer would drop it on the floor.
        extra = set(ds) - {"name", "kind", "deletionPolicy"}
        if extra:
            raise ValueError(
                f"{where}: datastore {ds['name']!r} of kind {kind!r} carries "
                f"{sorted(extra)}, but {kind} has no config block in var.tenants — "
                "the schemas have diverged and this renderer would silently drop it"
            )
        return out

    block = ds.get(kind)
    if block is None:
        return out

    mapped: dict = {}
    for k, v in block.items():
        target = FIELD_MAP[kind].get(k)
        if target is None:
            raise ValueError(
                f"{where}: datastore {ds['name']!r} sets {kind}.{k}, which has no "
                "counterpart in var.tenants — the CRD and the Terraform variable "
                "have diverged, so rendering it would drop the field silently"
            )
        if k == "globalSecondaryIndexes":
            v = [convert_gsi(g) for g in v]
        elif k in ("partitionKey", "sortKey"):
            v = dict(v)
        mapped[target] = v

    if mapped:
        out[BLOCK_KEY[kind]] = mapped
    return out


def load_platform(path: pathlib.Path) -> dict:
    """The Platform doc out of a multi-document tenant manifest."""
    docs = [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    platforms = [d for d in docs if d.get("kind") == "Platform"]
    if len(platforms) != 1:
        raise ValueError(
            f"{path}: expected exactly one Platform document, found {len(platforms)}"
        )
    return platforms[0]


def leaf_dir(environment: str) -> pathlib.Path:
    matches = sorted(LIVE.glob(f"workload-{environment}/*/{environment}/tenant-substrate"))
    if len(matches) != 1:
        raise SystemExit(
            f"expected exactly one tenant-substrate leaf for environment "
            f"{environment!r}, found {len(matches)}: {[str(m) for m in matches]}"
        )
    return matches[0]


def render(environment: str, source_root: pathlib.Path) -> dict:
    leaf = leaf_dir(environment)
    selection_path = leaf / "tenants.selection.yaml"
    if not selection_path.is_file():
        raise SystemExit(
            f"{selection_path.relative_to(ROOT)} does not exist — an environment "
            "provisions substrate only for the tenants it names there."
        )

    selection = yaml.safe_load(selection_path.read_text(encoding="utf-8")) or {}
    names = selection.get("tenants") or []
    if not isinstance(names, list):
        raise SystemExit(f"{selection_path}: `tenants` must be a list")

    out: dict = {}
    for name in names:
        cr_path = source_root / name / "platform.yaml"
        if not cr_path.is_file():
            raise SystemExit(
                f"tenant {name!r} is selected by {selection_path.relative_to(ROOT)} "
                f"but {cr_path} does not exist. The renderer resolves a tenant name "
                "to <source-root>/<name>/platform.yaml by convention."
            )
        platform = load_platform(cr_path)
        declared = platform["metadata"]["name"]
        if declared != name:
            raise SystemExit(
                f"{cr_path}: Platform is named {declared!r} but the selection asks "
                f"for {name!r}. The tenant key becomes part of every composed AWS "
                "resource name, so the two must agree."
            )
        datastores = platform.get("spec", {}).get("datastores", []) or []
        out[name] = {
            "datastores": [
                convert_datastore(d, str(cr_path.relative_to(source_root)))
                for d in datastores
            ]
        }
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--environment", required=True)
    ap.add_argument(
        "--source-root",
        type=pathlib.Path,
        default=ROOT.parent,
        help="directory holding the tenant app repos (default: landing-zone's parent)",
    )
    ap.add_argument(
        "--check",
        action="store_true",
        help="re-render and fail on any difference from the committed file",
    )
    args = ap.parse_args()

    try:
        rendered = render(args.environment, args.source_root)
    except ValueError as err:
        # A schema divergence or a malformed CR. The message names the field and
        # the file; a traceback would only bury it.
        print(f"FAIL  {err}")
        return 1
    target = leaf_dir(args.environment) / "tenants.generated.json"
    payload = json.dumps(rendered, indent=2, sort_keys=True) + "\n"

    if args.check:
        if not target.is_file():
            print(f"FAIL  {target.relative_to(ROOT)} does not exist — run:")
            print(f"      scripts/render-tenants.py --environment {args.environment}")
            return 1
        current = target.read_text(encoding="utf-8")
        if current != payload:
            print(f"FAIL  {target.relative_to(ROOT)} is stale.")
            print("      A Platform CR changed and the rendered substrate did not, so the")
            print("      tenant's declaration and its provisioned stores disagree. Run:")
            print(f"      scripts/render-tenants.py --environment {args.environment}")
            import difflib

            for line in difflib.unified_diff(
                current.splitlines(), payload.splitlines(),
                fromfile="committed", tofile="rendered", lineterm="",
            ):
                print(f"      {line}")
            return 1
        total = sum(len(t["datastores"]) for t in rendered.values())
        print(
            f"✓ {target.relative_to(ROOT)} matches the Platform CRs "
            f"({len(rendered)} tenant(s), {total} datastore(s))"
        )
        return 0

    target.write_text(payload, encoding="utf-8")
    total = sum(len(t["datastores"]) for t in rendered.values())
    print(
        f"wrote {target.relative_to(ROOT)} — {len(rendered)} tenant(s), "
        f"{total} datastore(s)"
    )
    return 0


# --- self-test ----------------------------------------------------------------

# A tenant manifest with every datastore kind and every mapped field, a second
# document that is not the Platform, and an empty one.
FULL_CR = """\
---
apiVersion: v1
kind: Namespace
metadata:
  name: alpha
---
---
apiVersion: platform.nanohype.dev/v1alpha1
kind: Platform
metadata:
  name: alpha
spec:
  datastores:
    - name: db
      kind: relational
      deletionPolicy: Retain
      relational: {engineVersion: "16.4", minACU: 0.5, maxACU: 4, backupRetentionDays: 7, deletionProtection: true}
    - name: table
      kind: keyValue
      keyValue:
        partitionKey: {name: pk, type: S}
        sortKey: {name: sk, type: N}
        billingMode: PAY_PER_REQUEST
        ttlAttribute: expires
        pointInTimeRecovery: true
        globalSecondaryIndexes:
          - {name: by-sk, partitionKey: {name: sk, type: N}, sortKey: {name: pk, type: S}, projection: ALL}
    - name: bucket
      kind: objectStore
      objectStore: {versioning: true, lifecycleExpireDays: 30}
    - name: jobs
      kind: queue
      queue: {fifo: true, visibilityTimeoutSeconds: 60, messageRetentionSeconds: 86400, maxReceiveCount: 5}
    - name: hot
      kind: cache
      cache: {engine: valkey, nodeType: cache.t4g.micro, replicas: 1}
    - name: events
      kind: stream
    - name: plain
      kind: objectStore
    - name: empty
      kind: queue
      queue: {}
"""
FULL_RENDERED = {"alpha": {"datastores": [
    {"name": "db", "kind": "relational", "deletion_policy": "Retain",
     "relational": {"engine_version": "16.4", "min_acu": 0.5, "max_acu": 4,
                    "backup_retention_days": 7, "deletion_protection": True}},
    {"name": "table", "kind": "keyValue",
     "key_value": {"partition_key": {"name": "pk", "type": "S"},
                   "sort_key": {"name": "sk", "type": "N"}, "billing_mode": "PAY_PER_REQUEST",
                   "ttl_attribute": "expires", "point_in_time_recovery": True,
                   "global_secondary_indexes": [
                       {"name": "by-sk", "partition_key": {"name": "sk", "type": "N"},
                        "sort_key": {"name": "pk", "type": "S"}, "projection": "ALL"}]}},
    {"name": "bucket", "kind": "objectStore",
     "object_store": {"versioning": True, "lifecycle_expire_days": 30}},
    {"name": "jobs", "kind": "queue",
     "queue": {"fifo": True, "visibility_timeout_seconds": 60,
               "message_retention_seconds": 86400, "max_receive_count": 5}},
    {"name": "hot", "kind": "cache",
     "cache": {"engine": "valkey", "node_type": "cache.t4g.micro", "replicas": 1}},
    {"name": "events", "kind": "stream"},
    {"name": "plain", "kind": "objectStore"},
    {"name": "empty", "kind": "queue"},
]}}
LEAF = "live/aws/workload-selftest/us-east-1/selftest/tenant-substrate"
SELECTION = f"{LEAF}/tenants.selection.yaml"
GENERATED = f"{LEAF}/tenants.generated.json"
ONE_STORE = "kind: Platform\nmetadata: {name: alpha}\nspec:\n  datastores:\n    - "

# (name, files in the scratch tree, arguments, exit status, words the output must
# carry). A status of None is a refusal raised as SystemExit, whose message the
# words are from.
CASES = [
    ("every kind and field rendered", {SELECTION: "tenants: [alpha]\n", "crs/alpha/platform.yaml":
                                       FULL_CR}, [], 0, "wrote "),
    ("a rendering that matches", {}, ["--check"], 0, "matches the Platform CRs"),
    ("a rendering gone stale", {"crs/alpha/platform.yaml": FULL_CR.replace("replicas: 1",
                                                                           "replicas: 2")},
     ["--check"], 1, "is stale"),
    ("a rendering that is not there", {GENERATED: None}, ["--check"], 1, "does not exist — run:"),
    ("a field with no counterpart", {"crs/alpha/platform.yaml": ONE_STORE +
                                     "{name: d, kind: relational, relational: {iops: 3}}\n"},
     [], 1, "has no counterpart in var.tenants"),
    ("a stream with a config block", {"crs/alpha/platform.yaml": ONE_STORE +
                                      "{name: s, kind: stream, stream: {shards: 1}}\n"},
     [], 1, "has no config block in var.tenants"),
    ("an index field with no counterpart", {"crs/alpha/platform.yaml": ONE_STORE +
                                            "{name: t, kind: keyValue, keyValue: "
                                            "{globalSecondaryIndexes: [{name: g, limit: 1}]}}\n"},
     [], 1, "globalSecondaryIndexes carries unmapped field"),
    ("two Platform documents", {"crs/alpha/platform.yaml": "kind: Platform\n---\nkind: Platform\n"},
     [], 1, "expected exactly one Platform document"),
    ("a Platform named for another tenant", {"crs/alpha/platform.yaml":
                                             "kind: Platform\nmetadata: {name: beta}\n"},
     [], None, "Platform is named 'beta'"),
    ("a selected tenant with no manifest", {"crs/alpha/platform.yaml": None}, [], None,
     "by convention"),
    ("tenants that are not a list", {SELECTION: "tenants: alpha\n"}, [], None, "must be a list"),
    ("no selection", {SELECTION: None}, [], None, "does not exist — an environment"),
    ("no leaf for the environment", {}, ["--environment", "nowhere"], None,
     "expected exactly one tenant-substrate leaf"),
]


def self_test() -> int:
    """Run main() over each case in one scratch tree, each case changing it in turn."""
    failures = []
    with tempfile.TemporaryDirectory(prefix="render-tenants-") as tmp:
        root = pathlib.Path(tmp)
        here = sys.modules[__name__]
        with mock.patch.object(here, "ROOT", root), mock.patch.object(here, "LIVE",
                                                                      root / "live" / "aws"):
            for name, files, args, status, says in CASES:
                for rel, text in files.items():
                    path = root / rel
                    if text is None:
                        path.unlink()
                    else:
                        path.parent.mkdir(parents=True, exist_ok=True)
                        path.write_text(text, encoding="utf-8")
                argv = ["render-tenants.py", "--environment", "selftest",
                        "--source-root", str(root / "crs"), *args]
                out = io.StringIO()
                with mock.patch.object(sys, "argv", argv), contextlib.redirect_stdout(out):
                    try:
                        code: int | None = main()
                    except SystemExit as e:
                        code, message = None, str(e)
                    else:
                        message = out.getvalue()
                if code != status or says not in message:
                    failures.append(f"[{name}] exited {code}, not {status} saying {says!r}: "
                                    f"{message.strip()[:160]}")
                if name == "every kind and field rendered" and json.loads(
                        (root / GENERATED).read_text(encoding="utf-8")) != FULL_RENDERED:
                    failures.append(f"[{name}] rendered something other than the expected "
                                    "var.tenants")
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    if failures:
        print(f"render-tenants self-test FAILED: {len(failures)} of {len(CASES)} case(s)",
              file=sys.stderr)
        return 1
    print(f"render-tenants self-test passed ({len(CASES)} cases: every kind and mapped field "
          "rendered, each divergence and malformed selection refused, and --check on a fresh, "
          "a stale and a missing rendering).")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(main())
