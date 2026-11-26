#!/usr/bin/env python3
"""Documentation must name the state key the backend writes.

live/root.hcl keys every leaf's state by the leaf's environment and its path
under live/:

    bucket = "${local.account_id}-${local.region}-tfstate"
    key    = "${local.environment}/${path_relative_to_include()}/terraform.tfstate"

So a leaf at live/aws/<account>/<region>/<env>/<component>/ keeps its state at

    s3://<account_id>-<region>-tfstate/<env>/aws/<account>/<region>/<env>/<component>/terraform.tfstate

and its lock at the same key with `.tflock` appended. The runbooks act on that
key during an incident. RB-002 lists and deletes a stuck lock by it, and RB-004
lists, downloads and restores a state version by it. A runbook that names a
shorter key, such as `<env>/<component>/terraform.tfstate`, lists nothing,
deletes nothing and restores nothing. Nobody finds that out until the incident
the runbook was written for.

WHAT THIS ASSERTS

Run with no arguments, it reads every tracked Markdown file outside fleet/ and
holds every state key and state bucket each one names to the backend's shape.

  - A key is the path of an S3 URL into a `-tfstate` bucket, a `--key` or
    `--prefix` argument naming a `tfstate` object, or any other path ending in
    `/terraform.tfstate` or `/terraform.tfstate.tflock`.
  - A key may stop short of the object, as the directory RB-002 lists does, but
    each segment it has must be the shape's segment at that position.
  - A placeholder is written `<name>` or `{name}`, in any case and with `-` or
    `_` (`{environment}` reads as `<env>`). A concrete value stands in for its
    placeholder. A key concrete in every directory segment must name a leaf
    that exists, and both of a key's environment segments must agree.
  - A bucket is `<account_id>-<region>-tfstate`, with a 12-digit id or a region
    standing in for either placeholder.

Three things are not keys this script can check, and it skips them:
  - a path holding a `$`, which is a shell or HCL expression, root.hcl's own
    included, not a key;
  - a `-backend-config=key=` value, which configures a root outside the live
    tree and so outside root.hcl;
  - fleet/: its roots take their key from a provider-opentofu Workspace's
    -backend-config, and their READMEs document that key.

Run with --rendered FILE, it checks the other half: that the backend writes the
shape this script holds the documentation to. CI's evaluate job renders every
live leaf and writes one `<leaf dir>\\t<bucket>\\t<key>` line for each. Every
tracked leaf must appear exactly once, with that leaf's key and a bucket named
for its region. A change to root.hcl's key therefore fails CI until this
script's shape changes with it, and then the documentation must follow.

Exit 0 = every documented key and bucket has the shape (with --rendered, every
leaf renders it). Exit 1 = a key or bucket off the shape, a concrete key naming
no leaf, a rendered leaf off the shape, missing or repeated, or a scan that saw
too little to report a pass. Exit 2 = usage.
"""

from __future__ import annotations

import contextlib
import io
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# The backend's key, segment by segment: root.hcl's environment, then the leaf's
# path under live/. A placeholder is <name>; any other segment is a literal.
KEY_SHAPE = ("<env>", "aws", "<account>", "<region>", "<env>", "<component>", "terraform.tfstate")
SHAPE_TEXT = "/".join(KEY_SHAPE)
LOCK = "terraform.tfstate.tflock"
BUCKET_TEXT = "<account_id>-<region>-tfstate"
BUCKET_SHAPE = re.compile(r"(?:<account_id>|\d{12})-(?:<region>|[a-z]{2}(?:-[a-z]+)+-\d+)-tfstate")
LEAF = re.compile(r"live/aws/(?P<account>[^/]+)/(?P<region>[^/]+)/(?P<env>[^/]+)/(?P<component>[^/]+)")

# The spellings of a placeholder the documentation uses, folded to the shape's.
SYNONYMS = {"environment": "env", "account_dir": "account"}

# The documentation names the key in eight places, five of them in the runbooks,
# and the scan reads several dozen files. Fewer than this means the scan, not the
# documentation, changed.
MIN_KEYS = 5
MIN_FILES = 10

S3_URL = re.compile(r"s3://(?P<bucket>[^/\s`'\"]+)(?P<path>/[^\s`'\"\\]*)?")
ARG_KEY = re.compile(r"--(?:key|prefix)[ =](?P<path>[^\s`'\"\\]+)")
BARE_KEY = re.compile(r"(?P<path>[^\s`'\"\\]*/terraform\.tfstate(?:\.tflock)?)(?![\w.])")
BUCKET = re.compile(r"(?P<bucket>[\w{}<>-]+-tfstate)(?![\w.-])")
PLACEHOLDER = re.compile(r"<([^<>/]+)>|\{([^{}/]+)\}")


def placeholder(segment: str) -> str | None:
    """The shape's name for a placeholder segment, or None for a literal one."""
    m = PLACEHOLDER.fullmatch(segment)
    if not m:
        return None
    name = (m.group(1) or m.group(2)).strip().lower().replace("-", "_")
    return SYNONYMS.get(name, name)


def key_problem(path: str, root: Path) -> str | None:
    """None when `path` has the backend's shape, else what is wrong with it."""
    segments = path.strip("/").split("/")
    full = segments[-1] in (KEY_SHAPE[-1], LOCK)
    directories = segments[:-1] if full else segments
    if full and len(segments) != len(KEY_SHAPE):
        return f"has {len(segments)} segments where the backend's key has {len(KEY_SHAPE)}"
    if len(directories) > len(KEY_SHAPE) - 1:
        return f"runs past the {len(KEY_SHAPE) - 1} directories the backend's key has"
    environments = set()
    for i, segment in enumerate(directories):
        want = KEY_SHAPE[i]
        name = placeholder(segment)
        if not want.startswith("<"):
            if segment != want:
                return f"has {segment!r} at segment {i + 1}, where the backend's key has {want!r}"
        elif name is not None and f"<{name}>" != want:
            return f"has <{name}> at segment {i + 1}, where the backend's key has {want}"
        elif name is None and want == "<env>":
            environments.add(segment)
    if len(environments) > 1:
        return f"names two environments ({', '.join(sorted(environments))})"
    if full and all(placeholder(s) is None for s in directories):
        leaf = "live/" + "/".join(directories[1:])
        if not (root / leaf / "terragrunt.hcl").is_file():
            return f"names {leaf}, which holds no terragrunt.hcl"
    return None


def findings(line: str, root: Path) -> list[tuple[str, str, str | None]]:
    """(kind, text, problem) for each state key and bucket `line` names."""
    found: list[tuple[str, str, str | None]] = []

    def key(path: str) -> None:
        path = path.strip("()[],.;:").lstrip("/")
        if "$" not in path:
            found.append(("key", path, key_problem(path, root)))

    rest = line
    for m in S3_URL.finditer(line):
        if m.group("bucket").endswith("-tfstate") and (m.group("path") or "/") != "/":
            key(m.group("path"))
        rest = rest.replace(m.group(0), " ")
    for m in ARG_KEY.finditer(rest):
        if "tfstate" in m.group("path"):
            key(m.group("path"))
        rest = rest.replace(m.group(0), " ")
    rest = re.sub(r"key=\S*", " ", rest)
    for m in BARE_KEY.finditer(rest):
        key(m.group("path"))
    for m in BUCKET.finditer(line):
        bucket = PLACEHOLDER.sub(lambda p: f"<{placeholder(p.group(0))}>", m.group("bucket"))
        problem = None if BUCKET_SHAPE.fullmatch(bucket) else f"is not {BUCKET_TEXT}"
        found.append(("bucket", m.group("bucket"), problem))
    return found


def tracked(root: Path, *patterns: str) -> list[str]:
    return subprocess.run(
        ["git", "-C", str(root), "ls-files", *patterns],
        capture_output=True, text=True, check=True, timeout=60,
    ).stdout.split()


def leaves(root: Path) -> list[str]:
    return sorted(p.rsplit("/", 1)[0] for p in tracked(root, "live/**/terragrunt.hcl")
                  if p.endswith("/terragrunt.hcl"))


def check_docs(root: Path = ROOT, min_files: int = MIN_FILES, min_keys: int = MIN_KEYS) -> int:
    files = [f for f in tracked(root, "*.md") if not f.startswith("fleet/")]
    if len(files) < min_files:
        print(f"::error::found {len(files)} tracked Markdown file(s) outside fleet/, expected at "
              f"least {min_files}. The scan did not see the documentation and refuses to report "
              f"a pass.")
        return 1
    counts = {"key": 0, "bucket": 0}
    bad: list[str] = []
    for rel in files:
        try:
            lines = (root / rel).read_text().splitlines()
        except (OSError, UnicodeDecodeError) as e:
            bad.append(f"{rel}: unreadable ({e})")
            continue
        for n, line in enumerate(lines, 1):
            for kind, text, problem in findings(line, root):
                counts[kind] += 1
                if problem:
                    bad.append(f"{rel}:{n}: state {kind} {text} {problem}")
    if bad:
        print("Documented state keys and buckets the backend does not write:\n", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        print(f"\nlive/root.hcl keys a leaf at live/aws/<account>/<region>/<env>/<component>/ at "
              f"{SHAPE_TEXT}\n(its lock at the same key with .tflock appended), in the bucket "
              f"{BUCKET_TEXT}.\nA runbook naming any other key acts on nothing.", file=sys.stderr)
        return 1
    if counts["key"] < min_keys:
        print(f"::error::found {counts['key']} documented state key(s), expected at least "
              f"{min_keys}. The scan stopped recognising them and refuses to report a pass.")
        return 1
    print(f"✓ every documented state key and bucket has the backend's shape ({counts['key']} "
          f"key(s) and {counts['bucket']} bucket(s) in {len(files)} file(s))")
    return 0


def check_rendered(text: str, root: Path = ROOT) -> int:
    expected = leaves(root)
    seen: dict[str, int] = {}
    bad: list[str] = []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            bad.append(f"line {n}: not <leaf dir>\\t<bucket>\\t<key>: {line!r}")
            continue
        leaf, bucket, key = parts
        m = LEAF.fullmatch(leaf)
        if not m:
            bad.append(f"{leaf}: not a leaf at live/aws/<account>/<region>/<env>/<component>")
            continue
        seen[leaf] = seen.get(leaf, 0) + 1
        want = "/".join(m.group(s[1:-1]) if s.startswith("<") else s for s in KEY_SHAPE)
        if key != want:
            bad.append(f"{leaf}: renders the key {key}, where {SHAPE_TEXT} gives {want}")
        if not re.fullmatch(rf"\d{{12}}-{re.escape(m.group('region'))}-tfstate", bucket):
            bad.append(f"{leaf}: renders the bucket {bucket}, not {BUCKET_TEXT} for its region")
    for leaf in expected:
        if seen.get(leaf, 0) != 1:
            bad.append(f"{leaf}: rendered {seen.get(leaf, 0)} time(s), where every leaf renders once")
    bad.extend(f"{leaf}: rendered, but no tracked terragrunt.hcl is there"
               for leaf in sorted(set(seen) - set(expected)))
    if not expected:
        bad.append("no tracked leaf under live/, so there is nothing to compare the render with")
    if bad:
        print("Rendered state keys off the shape the documentation is held to:\n", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        return 1
    print(f"✓ every one of {len(expected)} leaves renders its state at {SHAPE_TEXT} in "
          f"{BUCKET_TEXT}")
    return 0


# ---------------------------------------------------------------- self-test

GOOD = SHAPE_TEXT
BUCKET_URL = "s3://<account_id>-<region>-tfstate"
REAL_LEAF = "live/aws/workload-development/us-east-1/development/network"
REAL_KEY = "development/aws/workload-development/us-east-1/development/network/terraform.tfstate"

# (name, line, findings it must report as (kind, bad) pairs, text a problem must hold)
LINES = [
    ("RB-002's old lock key", f"aws s3 rm {BUCKET_URL}/<env>/<component>/terraform.tfstate.tflock",
     [("key", True), ("bucket", False)], "has 3 segments"),
    ("the lock at the backend's key", f"aws s3 rm {BUCKET_URL}/{GOOD}.tflock",
     [("key", False), ("bucket", False)], ""),
    ("RB-002's old listing", f"aws s3 ls {BUCKET_URL}/<env>/<component>/",
     [("key", True), ("bucket", False)], "has '<component>' at segment 2, where the backend's key has 'aws'"),
    ("the listing of a leaf's directory", f"aws s3 ls {BUCKET_URL}/{GOOD.rsplit('/', 1)[0]}/",
     [("key", False), ("bucket", False)], ""),
    ("an environment's directory", f"aws s3 ls {BUCKET_URL}/<env>/", [("key", False), ("bucket", False)], ""),
    ("the bucket alone", f"aws s3 ls {BUCKET_URL}/", [("bucket", False)], ""),
    ("RB-004's old prefix", "--prefix <env>/<component>/terraform.tfstate", [("key", True)], "has 3 segments"),
    ("a --key at the backend's key", f"--key {GOOD} \\", [("key", False)], ""),
    ("a --key= form", f"--key={GOOD}", [("key", False)], ""),
    ("a --key naming no state", "--key secrets/app.json", [], ""),
    ("braces", "`{env}/aws/{account}/{region}/{env}/{component}/terraform.tfstate`", [("key", False)], ""),
    ("synonyms and case", "`{ENVIRONMENT}/aws/<account-dir>/<Region>/{environment}/<component>/terraform.tfstate`",
     [("key", False)], ""),
    ("the old braces form", "keyed `{env}/{component}/terraform.tfstate`, with", [("key", True)], "has 3 segments"),
    ("a concrete leaf's key", f"rendered `{REAL_KEY}`", [("key", False)], ""),
    ("a concrete key naming no leaf", f"`{REAL_KEY.replace('network', 'nowhere')}`", [("key", True)],
     "holds no terragrunt.hcl"),
    ("two environments", "development/aws/<account>/<region>/staging/<component>/terraform.tfstate",
     [("key", True)], "names two environments (development, staging)"),
    ("a placeholder the shape lacks", "<env>/aws/<account>/<region>/<env>/<leaf>/terraform.tfstate",
     [("key", True)], "has <leaf> at segment 6, where the backend's key has <component>"),
    ("another cloud", "<env>/gcp/<account>/<region>/<env>/<component>/terraform.tfstate", [("key", True)],
     "has 'gcp' at segment 2, where the backend's key has 'aws'"),
    ("a directory past the leaf", f"aws s3 ls {BUCKET_URL}/{GOOD.rsplit('/', 1)[0]}/extra/",
     [("key", True), ("bucket", False)], "runs past the 6 directories"),
    ("a key in parentheses", f"(see {GOOD}).", [("key", False)], ""),
    ("a local file beside a key", f"aws s3 cp terraform.tfstate.backup {BUCKET_URL}/{GOOD}",
     [("key", False), ("bucket", False)], ""),
    ("a -backend-config key", "-backend-config=key=fleet/<name>/terraform.tfstate \\", [], ""),
    ("root.hcl's expression", "`${local.environment}/${path_relative_to_include()}/terraform.tfstate`", [], ""),
    ("a shell variable", 'aws s3 rm "s3://<account_id>-<region>-tfstate/${KEY}.tflock"', [("bucket", False)], ""),
    ("a bucket in braces", "Buckets are named `{account_id}-{region}-tfstate`", [("bucket", False)], ""),
    ("a concrete bucket", "s3://123456789012-us-east-1-tfstate/", [("bucket", False)], ""),
    ("a bucket without its region", "s3://<account_id>-tfstate/", [("bucket", True)],
     "is not <account_id>-<region>-tfstate"),
    ("a bucket with a short id", "`12345-us-east-1-tfstate`", [("bucket", True)], "is not"),
    ("an S3 URL outside the state buckets", "s3://my-artifacts/terraform/plan.out", [], ""),
    ("prose with no key", "State lives in S3 with native locking.", [], ""),
]


def fixture(files: dict[str, str | bytes], leaf_dirs=(REAL_LEAF,)) -> tempfile.TemporaryDirectory:
    tmp = tempfile.TemporaryDirectory(prefix="state-key-self-test-")
    root = Path(tmp.name)
    for leaf in leaf_dirs:
        (root / leaf).mkdir(parents=True, exist_ok=True)
        (root / leaf / "terragrunt.hcl").write_text("# probe\n")
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        if isinstance(text, bytes):
            (root / rel).write_bytes(text)
        else:
            (root / rel).write_text(text)
    subprocess.run(["git", "init", "-q", str(root)], check=True, timeout=60)
    subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, timeout=60)
    return tmp


def run(fn, *args) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        status = fn(*args)
    return status, out.getvalue()


def docs(extra: dict[str, str] | None = None, keys: int = MIN_KEYS) -> dict[str, str]:
    files = {f"docs/d{i}.md": f"Probe {i}.\n" for i in range(MIN_FILES)}
    files["docs/runbook.md"] = "".join(f"aws s3 rm {BUCKET_URL}/{GOOD}.tflock\n" for _ in range(keys))
    files.update(extra or {})
    return files


def rendered(rows: list[tuple[str, str, str]]) -> str:
    return "".join("\t".join(r) + "\n" for r in rows)


GOOD_ROW = (REAL_LEAF, "111111111111-us-east-1-tfstate", REAL_KEY)
SECOND_LEAF = "live/aws/backup/us-east-1/shared/backup"
SECOND_ROW = (SECOND_LEAF, "111111111111-us-east-1-tfstate",
              "shared/aws/backup/us-east-1/shared/backup/terraform.tfstate")

# (name, docs, leaves, rendered or None for the docs check, status, text the output holds)
RUNS = [
    ("documentation at the backend's key", docs(), (REAL_LEAF,), None, 0, "✓ every documented"),
    ("a runbook at the old key", docs({"docs/rb.md": "x\naws s3 rm s3://b-tfstate/<env>/<c>/terraform.tfstate\n"}),
     (REAL_LEAF,), None, 1, "docs/rb.md:2: state key <env>/<c>/terraform.tfstate has 3 segments"),
    ("fleet's own -backend-config keys", docs({"fleet/aws/x/README.md": "<name>/terraform.tfstate\n"}),
     (REAL_LEAF,), None, 0, "✓"),
    ("too few documents", {"docs/a.md": f"{GOOD}\n"}, (REAL_LEAF,), None, 1, "refuses to report a pass"),
    ("too few keys", docs(keys=MIN_KEYS - 1), (REAL_LEAF,), None, 1,
     f"found {MIN_KEYS - 1} documented state key(s)"),
    ("a document that is not text", {**docs(), "docs/binary.md": b"\xff\xfe"}, (REAL_LEAF,), None, 1,
     "docs/binary.md: unreadable"),
    ("every leaf rendered at its key", docs(), (REAL_LEAF, SECOND_LEAF), [GOOD_ROW, SECOND_ROW], 0,
     "✓ every one of 2 leaves"),
    ("a leaf rendered off the shape", docs(), (REAL_LEAF,),
     [(REAL_LEAF, GOOD_ROW[1], "development/network/terraform.tfstate")], 1,
     f"{REAL_LEAF}: renders the key development/network/terraform.tfstate, where"),
    ("a bucket for another region", docs(), (REAL_LEAF,),
     [(REAL_LEAF, "111111111111-elsewhere-tfstate", REAL_KEY)], 1, "renders the bucket 111111111111-elsewhere"),
    ("a leaf never rendered", docs(), (REAL_LEAF, SECOND_LEAF), [GOOD_ROW], 1,
     f"{SECOND_LEAF}: rendered 0 time(s)"),
    ("a leaf rendered twice", docs(), (REAL_LEAF,), [GOOD_ROW, GOOD_ROW], 1, "rendered 2 time(s)"),
    ("a render for no tracked leaf", docs(), (REAL_LEAF,), [GOOD_ROW, SECOND_ROW], 1,
     f"{SECOND_LEAF}: rendered, but no tracked terragrunt.hcl"),
    ("a malformed line", docs(), (REAL_LEAF,), [GOOD_ROW, ("only", "two")], 1, "line 2: not <leaf dir>"),
    ("a row that is not a leaf", docs(), (REAL_LEAF,), [GOOD_ROW, ("live/root.hcl", "b", "k")], 1,
     "live/root.hcl: not a leaf"),
    ("no leaf at all", docs(), (), [], 1, "no tracked leaf under live/"),
]


def self_test(lines=tuple(LINES), runs=tuple(RUNS), meta: bool = True) -> int:
    failures: list[str] = []
    with fixture({}) as tmp:
        root = Path(tmp)
        for name, line, want, says in lines:
            got = findings(line, root)
            if [(kind, problem is not None) for kind, _, problem in got] != want or \
                    (says and not any(says in (p or "") for _, _, p in got)):
                failures.append(f"{name}: {line!r} gave {got}, wanted {want} saying {says!r}")
    for name, files, leaf_dirs, rows, want, says in runs:
        with fixture(files, leaf_dirs) as tmp:
            root = Path(tmp)
            if rows is None:
                status, output = run(check_docs, root)
            else:
                status, output = run(check_rendered, rendered(rows), root)
        if status != want or says not in output:
            failures.append(f"{name}: exit {status}, wanted {want} with {says!r}\n"
                            + "".join(f"      {line}\n" for line in output.splitlines()[-6:]))
    for args, want in ((["--rendered"], 2), (["--bogus"], 2), (["--rendered", "/nonexistent/keys.tsv"], 1)):
        status, output = run(cli, args)
        if status != want:
            failures.append(f"arguments {args}: exit {status}, wanted {want}\n      {output.strip()}")
    if meta:
        # A self-test over a case it gets wrong must fail, or it proves nothing.
        wrong = [(LINES[0][0], LINES[0][1], [("key", False), ("bucket", False)], "")]
        if run(self_test, wrong, (), False)[0] == 0:
            failures.append("a self-test whose case expects RB-002's old key to pass did not fail")
    if failures:
        print("check-state-key-docs.py --self-test FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print(f"check-state-key-docs.py --self-test: {len(lines)} line(s) and {len(runs)} run(s) behave "
          f"as the rules say, and a self-test over a wrong case fails.")
    return 0


def cli(args: list[str]) -> int:
    if not args:
        return check_docs()
    if args == ["--self-test"]:
        return self_test()
    if len(args) == 2 and args[0] == "--rendered":
        try:
            text = Path(args[1]).read_text()
        except OSError as e:
            print(f"::error::could not read the rendered keys at {args[1]}: {e}")
            return 1
        return check_rendered(text)
    print("usage: check-state-key-docs.py [--self-test | --rendered FILE]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
