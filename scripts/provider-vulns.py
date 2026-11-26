#!/usr/bin/env python3
"""Every locked provider is maintained, and takes the fixes its maintainers ship.

A provider runs inside every plan and apply, with every credential the run
holds. When one of its dependencies publishes a fix, the provider carries it
only once its maintainers rebuild and release, and this repository runs it only
once the lock files take that release. Nothing in a plan or an apply shows which
vulnerable code a provider links.

govulncheck's binary mode does. It reads a binary's module versions and symbol
table, and reports each vulnerability whose vulnerable functions are linked in.
Most maintained providers carry some even at their newest release, because
advisories land faster than providers rebuild. A check that failed on every
finding would fail every pull request with nothing to take. This one fails only
on the two findings this repository can act on:

  ABANDONED     A provider carries findings and has published no release in
                365 days. Its maintainers have stopped taking fixes, so the
                findings only grow. The remedy is to replace the provider;
                cluster-bootstrap uses alekc/kubectl, the maintained fork of
                gavinbunney/kubectl, for that reason.
  UNTAKEN FIX   A newer release, published at least 3 days ago (the
                organisation's Renovate floor), no longer carries a finding
                the locked version does. The remedy is to take it; Renovate
                proposes it once the floor has passed.

Every other finding is listed in the summary, provider by provider, and in the
job summary when GITHUB_STEP_SUMMARY is set.

HOW

The providers are the ones the committed .terraform.lock.hcl files lock, each
version checked once. For each one:

  1. The registry (registry.opentofu.org, through the provider registry
     protocol) names the linux_amd64 package and its SHA-256. A lock file must
     already hold that SHA-256 as a zh: hash, and the downloaded zip must hash
     to it, so the binary scanned is the one every init here installs.
  2. `govulncheck -mode=binary -format json` scans it. A finding counts when
     govulncheck traces it to a linked function.
  3. If there are findings, release dates come into it. A release's date is
     the published_at of the GitHub release behind the registry's download
     URL. The registry's own per-version timestamps are not used: they record
     when the registry learned of a version, and its backfill gave old
     versions recent dates.
  4. The newest stable version's date decides ABANDONED. The newest stable
     version past the floor is downloaded, verified against the registry's
     SHA-256 and scanned, and the two sets of findings decide UNTAKEN FIX.

A provider that cannot be checked (a download, hash, scan or date that fails)
fails the run. A blocking check that cannot see a provider cannot clear it.

Exit 0 = no provider is abandoned or behind a fix it can take. Exit 1 = one is,
one could not be checked, or the lock files named too few providers to check.
Exit 2 = usage.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = "https://registry.opentofu.org/v1/providers"
GITHUB_API = "https://api.github.com"
ABANDONED = dt.timedelta(days=365)
FLOOR = dt.timedelta(days=3)
PLATFORM = "linux/amd64"
HTTP_TIMEOUT = 120
SCAN_TIMEOUT = 900
ATTEMPTS = 3
# The lock files lock ten providers between them. Fewer than this means the
# lock files were not read, not that the repository stopped using providers.
MIN_PROVIDERS = 5

LOCK_BLOCK = re.compile(r'provider "(?P<address>[^"]+)" \{(?P<body>.*?)\n\}', re.S)
LOCK_VERSION = re.compile(r'^\s*version\s*=\s*"(?P<version>[^"]+)"', re.M)
ZH = re.compile(r'"zh:([0-9a-f]{64})"')
STABLE = re.compile(r"\d+\.\d+\.\d+")
RELEASE_ASSET = re.compile(
    r"https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/releases/download/(?P<tag>[^/]+)/[^/]+")


class CheckError(Exception):
    """A provider that could not be checked, which fails the run."""


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(p) for p in version.split("."))


def linked_findings(stream: str) -> dict[str, str]:
    """{advisory id: module} for each finding govulncheck traces to a linked function."""
    decoder, i, found = json.JSONDecoder(), 0, {}
    while i < len(stream):
        while i < len(stream) and stream[i].isspace():
            i += 1
        if i == len(stream):
            break
        obj, i = decoder.raw_decode(stream, i)
        finding = obj.get("finding")
        if finding and finding.get("trace") and finding["trace"][0].get("function"):
            found[finding["osv"]] = finding["trace"][0].get("module", "")
    return found


class World:
    """The network and the scanner. The self-test substitutes its own."""

    def __init__(self, db: str | None = None, govulncheck: str = "govulncheck"):
        self.db = db
        self.govulncheck = govulncheck
        self.token = os.environ.get("GITHUB_TOKEN", "")

    def now(self) -> dt.datetime:
        return dt.datetime.now(dt.timezone.utc)

    def fetch(self, url: str) -> bytes:
        headers = {"User-Agent": "landing-zone-provider-vulns"}
        if url.startswith(GITHUB_API + "/"):
            headers["Accept"] = "application/vnd.github+json"
            if self.token:
                headers["Authorization"] = f"Bearer {self.token}"
        problem: Exception | None = None
        for attempt in range(ATTEMPTS):
            try:
                with urllib.request.urlopen(urllib.request.Request(url, headers=headers),
                                            timeout=HTTP_TIMEOUT) as response:
                    return response.read()
            except urllib.error.HTTPError as e:
                problem = e
                if e.code < 500 and e.code != 429:
                    break  # a request the server refuses is refused again
            except (urllib.error.URLError, OSError) as e:
                problem = e
            if attempt + 1 < ATTEMPTS:
                time.sleep(2 ** attempt)
        raise CheckError(f"GET {url}: {problem}")

    def scan(self, binary: Path) -> dict[str, str]:
        cmd = [self.govulncheck, "-mode=binary", "-format", "json"]
        if self.db:
            cmd += ["-db", self.db]
        try:
            run = subprocess.run(cmd + [str(binary)], capture_output=True, text=True,
                                 timeout=SCAN_TIMEOUT)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise CheckError(f"govulncheck on {binary.name}: {e}") from e
        # In JSON mode govulncheck exits 0 whether or not it finds anything, so
        # any other status is a scan that did not happen.
        if run.returncode != 0:
            raise CheckError(f"govulncheck on {binary.name} exited {run.returncode}: "
                             f"{run.stderr.strip()[-300:]}")
        return linked_findings(run.stdout)


class Provider:
    """One locked provider version, and what checking it found."""

    def __init__(self, address: str, version: str, hashes: set[str]):
        self.address, self.version, self.hashes = address, version, hashes
        self.newest = ""
        self.newest_released: dt.datetime | None = None
        self.found: dict[str, str] = {}
        self.blocks: list[str] = []
        self.notes: list[str] = []
        self.error = ""

    def verdict(self) -> str:
        if self.error:
            return "could not be checked"
        if self.blocks:
            return "BLOCKS: " + "; ".join(b.split(":")[0] for b in self.blocks)
        return "listed" if self.found else "no linked findings"


def tracked(root: Path, *patterns: str) -> list[str]:
    return subprocess.run(["git", "-C", str(root), "ls-files", *patterns],
                          capture_output=True, text=True, check=True, timeout=60).stdout.split()


def locked(root: Path) -> list[Provider]:
    """Each provider version a committed lock file locks, with every zh: hash locked for it."""
    found: dict[tuple[str, str], set[str]] = {}
    for rel in tracked(root, "*.terraform.lock.hcl"):
        for block in LOCK_BLOCK.finditer((root / rel).read_text()):
            version = LOCK_VERSION.search(block.group("body"))
            if not version:
                raise CheckError(f"{rel}: provider {block.group('address')} locks no version")
            key = (block.group("address"), version.group("version"))
            found.setdefault(key, set()).update(ZH.findall(block.group("body")))
    return [Provider(address, version, hashes) for (address, version), hashes in sorted(found.items())]


def registry_path(address: str) -> str:
    host, _, rest = address.partition("/")
    if host != "registry.opentofu.org" or rest.count("/") != 1:
        raise CheckError(f"{address} is not a registry.opentofu.org provider address")
    return rest


def package(world: World, address: str, version: str) -> dict:
    return json.loads(world.fetch(f"{REGISTRY}/{registry_path(address)}/{version}/download/{PLATFORM}"))


def binary(world: World, pkg: dict, workdir: Path, locked_hashes: set[str] | None) -> Path:
    """The provider binary in `pkg`, verified, written under `workdir`."""
    shasum, name = pkg["shasum"], pkg["filename"]
    if locked_hashes is not None and shasum not in locked_hashes:
        raise CheckError(f"the registry's {name} hashes to {shasum}, which no lock file holds as zh:")
    data = world.fetch(pkg["download_url"])
    got = hashlib.sha256(data).hexdigest()
    if got != shasum:
        raise CheckError(f"{name} hashes to {got}, not the registry's {shasum}")
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = [m for m in archive.namelist() if Path(m).name.startswith("terraform-provider-")]
        if len(members) != 1:
            raise CheckError(f"{name} holds {len(members)} provider binaries, not one")
        target = workdir / Path(members[0]).name
        target.write_bytes(archive.read(members[0]))
    return target


def released(world: World, pkg: dict) -> dt.datetime:
    asset = RELEASE_ASSET.fullmatch(pkg["download_url"])
    if not asset:
        raise CheckError(f"{pkg['download_url']} is not a GitHub release asset, so its release "
                         f"date cannot be read")
    release = json.loads(world.fetch(
        f"{GITHUB_API}/repos/{asset['owner']}/{asset['repo']}/releases/tags/{asset['tag']}"))
    return dt.datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))


def check(world: World, p: Provider, workdir: Path) -> None:
    pkg = package(world, p.address, p.version)
    p.found = world.scan(binary(world, pkg, workdir, p.hashes))
    listing = json.loads(world.fetch(f"{REGISTRY}/{registry_path(p.address)}/versions"))
    stable = sorted((v["version"] for v in listing["versions"] if STABLE.fullmatch(v["version"])),
                    key=version_key)
    p.newest = stable[-1] if stable else p.version
    if not p.found:
        return
    newest_pkg = pkg if p.newest == p.version else package(world, p.address, p.newest)
    p.newest_released = released(world, newest_pkg)
    now = world.now()
    if now - p.newest_released > ABANDONED:
        p.blocks.append(f"ABANDONED: {len(p.found)} linked finding(s), and no release since "
                        f"{p.newest} on {p.newest_released:%Y-%m-%d}. Replace the provider.")
    for version in reversed(stable):
        if version_key(version) <= version_key(p.version):
            break
        pkg_v = newest_pkg if version == p.newest else package(world, p.address, version)
        when = p.newest_released if version == p.newest else released(world, pkg_v)
        if now - when < FLOOR:
            p.notes.append(f"{version}, published {when:%Y-%m-%d %H:%M}Z, is inside the "
                           f"{FLOOR.days}-day floor until {when + FLOOR:%Y-%m-%d %H:%M}Z")
            continue
        cleared = sorted(set(p.found) - set(world.scan(binary(world, pkg_v, workdir, None))))
        if cleared:
            p.blocks.append(f"UNTAKEN FIX: {version}, published {when:%Y-%m-%d}, no longer carries "
                            f"{', '.join(cleared)}. Take it.")
        else:
            p.notes.append(f"{version}, published {when:%Y-%m-%d}, clears none of these")
        break


def report(providers: list[Provider]) -> str:
    lines = ["| Provider | Locked | Newest | Newest released | Linked findings | Verdict |",
             "|---|---|---|---|---|---|"]
    for p in providers:
        when = f"{p.newest_released:%Y-%m-%d}" if p.newest_released else "—"
        lines.append(f"| `{p.address}` | {p.version} | {p.newest or '—'} | {when} | "
                     f"{len(p.found)} | {p.verdict()} |")
    for p in providers:
        if p.found or p.error or p.notes:
            lines += ["", f"**`{p.address}` {p.version}**", ""]
            lines += [f"- {line}" for line in [p.error] + p.blocks + p.notes if line]
            if p.found:
                lines.append("- linked: " + ", ".join(f"{i} ({m})" for i, m in sorted(p.found.items())))
    return "\n".join(lines) + "\n"


def main(world: World | None = None, root: Path = ROOT, min_providers: int = MIN_PROVIDERS) -> int:
    world = world or World()
    try:
        providers = locked(root)
    except (CheckError, OSError, subprocess.SubprocessError) as e:
        print(f"::error::could not read the lock files: {e}")
        return 1
    if len(providers) < min_providers:
        print(f"::error::the lock files name {len(providers)} provider version(s), expected at "
              f"least {min_providers}. The check did not see them and refuses to report a pass.")
        return 1
    for p in providers:
        with tempfile.TemporaryDirectory(prefix="provider-vulns-") as tmp:
            try:
                check(world, p, Path(tmp))
            except (CheckError, KeyError, ValueError, zipfile.BadZipFile) as e:
                p.error = f"could not be checked: {e}"
    summary = report(providers)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("## Locked providers\n\n" + summary)
    failing = [p for p in providers if p.blocks or p.error]
    for p in failing:
        for line in [p.error] + p.blocks:
            if line:
                print(f"::error title={p.address} {p.version}::{line}")
    if failing:
        return 1
    print(f"✓ none of {len(providers)} locked provider version(s) is abandoned or behind a fix "
          f"it can take")
    return 0


# ---------------------------------------------------------------- self-test

NOW = dt.datetime(2026, 11, 26, 12, 0, tzinfo=dt.timezone.utc)


def days_ago(n: float) -> str:
    return (NOW - dt.timedelta(days=n)).strftime("%Y-%m-%dT%H:%M:%SZ")


def archive(name: str, payload: bytes = b"\x7fELF probe") -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        z.writestr(name, payload)
    return out.getvalue()


class FakeWorld(World):
    """A registry, GitHub and govulncheck held in memory.

    `releases` maps "ns/name" to {version: (days since release, findings,
    download host[, the zip's one member])}; every version is in the
    registry's list.
    """

    def __init__(self, releases: dict, overrides: dict | None = None):
        super().__init__()
        self.urls: dict[str, bytes] = {}
        self.findings: dict[str, dict[str, str]] = {}
        self.scans: list[str] = []
        self.fetched: list[str] = []
        for path, versions in releases.items():
            name = path.split("/")[1]
            listing = {"versions": [{"version": v} for v in versions]}
            self.urls[f"{REGISTRY}/{path}/versions"] = json.dumps(listing).encode()
            for version, spec in versions.items():
                age, found, host = spec[:3]
                exe = f"terraform-provider-{name}_v{version}"
                data = archive(spec[3] if len(spec) > 3 else exe, f"{path} {version}".encode())
                url = f"https://{host}/{path.split('/')[0]}/terraform-provider-{name}/releases/download/v{version}/x.zip"
                pkg = {"filename": f"terraform-provider-{name}_{version}_linux_amd64.zip",
                       "download_url": url, "shasum": hashlib.sha256(data).hexdigest()}
                self.urls[f"{REGISTRY}/{path}/{version}/download/{PLATFORM}"] = json.dumps(pkg).encode()
                self.urls[url] = data
                self.urls[f"{GITHUB_API}/repos/{path.split('/')[0]}/terraform-provider-{name}/releases/tags/v{version}"] = \
                    json.dumps({"published_at": days_ago(age)}).encode()
                self.findings[exe] = found
        self.urls.update(overrides or {})

    def now(self) -> dt.datetime:
        return NOW

    def fetch(self, url: str) -> bytes:
        self.fetched.append(url)
        if url not in self.urls or self.urls[url] is None:
            raise CheckError(f"GET {url}: HTTP Error 404: Not Found")
        return self.urls[url]

    def scan(self, binary: Path) -> dict[str, str]:
        self.scans.append(binary.name)
        found = self.findings[binary.name]
        if found is None:
            raise CheckError(f"govulncheck on {binary.name} exited 2: probe")
        return dict(found)


GH = "github.com"
F1 = {"GO-2026-0001": "golang.org/x/net"}
F2 = {"GO-2026-0001": "golang.org/x/net", "GO-2026-0002": "stdlib"}


def lock(address: str, version: str, zh: list[str]) -> str:
    hashes = "".join(f'    "zh:{h}",\n' for h in zh)
    return f'provider "{address}" {{\n  version     = "{version}"\n  hashes = [\n{hashes}  ]\n}}\n'


def zh_of(world: FakeWorld, path: str, version: str) -> str:
    return json.loads(world.urls[f"{REGISTRY}/{path}/{version}/download/{PLATFORM}"])["shasum"]


def run_case(releases: dict, locks: dict[str, list[tuple[str, str]]], overrides=None, tamper=None,
             min_providers: int = 1, summary: bool = False) -> tuple[int, str, FakeWorld]:
    world = FakeWorld(releases, overrides)
    with tempfile.TemporaryDirectory(prefix="provider-vulns-self-test-") as tmp:
        root = Path(tmp)
        for rel, entries in locks.items():
            text = ""
            for entry in entries:
                if isinstance(entry, str):
                    text += entry
                    continue
                path, version = entry
                hashes = [zh_of(world, path, version)] if path in releases else []
                if tamper == (path, version):
                    hashes = ["0" * 64]
                text += lock(f"registry.opentofu.org/{path}", version, hashes)
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(text)
        subprocess.run(["git", "init", "-q", str(root)], check=True, timeout=60)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, timeout=60)
        out = io.StringIO()
        env = {"GITHUB_STEP_SUMMARY": str(root / "summary.md")} if summary else {}
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(out):
            status = main(world, root, min_providers)
        if summary:
            out.write("SUMMARY FILE:\n" + (root / "summary.md").read_text())
    return status, out.getvalue(), world


LOCK = "components/aws/x/.terraform.lock.hcl"


def cases() -> list[tuple[str, dict, dict, dict, int, str]]:
    """(name, releases, locks, run_case keyword arguments, status, text the output holds)."""
    one = lambda path, version: {LOCK: [(path, version)]}  # noqa: E731
    return [
        ("a provider with no linked findings", {"a/clean": {"1.0.0": (900, {}, GH)}},
         one("a/clean", "1.0.0"), {}, 0, "| no linked findings |"),
        ("findings at a maintained newest release", {"a/kept": {"1.0.0": (30, F1, GH)}},
         one("a/kept", "1.0.0"), {}, 0, "| 1 | listed |"),
        ("findings and no release in a year", {"a/stale": {"1.0.0": (400, F1, GH)}},
         one("a/stale", "1.0.0"), {}, 1, "ABANDONED: 1 linked finding(s), and no release since 1.0.0"),
        ("a release past the floor clears a finding",
         {"a/behind": {"1.0.0": (40, F2, GH), "1.1.0": (10, F1, GH)}},
         one("a/behind", "1.0.0"), {}, 1, "UNTAKEN FIX: 1.1.0, published 2026-11-16, no longer carries GO-2026-0002"),
        ("a release inside the floor waits",
         {"a/fresh": {"1.0.0": (40, F2, GH), "1.1.0": (1, F1, GH)}},
         one("a/fresh", "1.0.0"), {}, 0, "1.1.0, published 2026-11-25 12:00Z, is inside the 3-day floor"),
        ("the newest past the floor behind a fresh one decides",
         {"a/two": {"1.0.0": (40, F2, GH), "1.1.0": (10, F1, GH), "1.2.0": (1, {}, GH)}},
         one("a/two", "1.0.0"), {}, 1, "UNTAKEN FIX: 1.1.0"),
        ("a newer release that clears nothing",
         {"a/same": {"1.0.0": (40, F1, GH), "1.1.0": (10, F2, GH)}},
         one("a/same", "1.0.0"), {}, 0, "1.1.0, published 2026-11-16, clears none of these"),
        ("both: abandoned, and behind a fix",
         {"a/both": {"1.0.0": (800, F2, GH), "1.1.0": (500, F1, GH)}},
         one("a/both", "1.0.0"), {}, 1, "BLOCKS: ABANDONED; UNTAKEN FIX"),
        ("pre-releases are not the newest",
         {"a/pre": {"1.0.0": (30, F1, GH), "1.1.0-beta1": (2, {}, GH)}},
         one("a/pre", "1.0.0"), {}, 0, "/a/pre` | 1.0.0 | 1.0.0 |"),
        ("a registry package no lock file holds", {"a/tamper": {"1.0.0": (30, {}, GH)}},
         one("a/tamper", "1.0.0"), {"tamper": ("a/tamper", "1.0.0")}, 1, "which no lock file holds as zh:"),
        ("a download that does not hash to the registry's sum", {"a/swap": {"1.0.0": (30, {}, GH)}},
         one("a/swap", "1.0.0"),
         {"overrides": {"https://github.com/a/terraform-provider-swap/releases/download/v1.0.0/x.zip":
                        archive("terraform-provider-swap_v1.0.0", b"other")}}, 1, "not the registry's"),
        ("a zip with no provider in it", {"a/empty": {"1.0.0": (30, {}, GH, "README.md")}},
         one("a/empty", "1.0.0"), {}, 1, "holds 0 provider binaries"),
        ("a lock entry with no version", {},
         {LOCK: ['provider "registry.opentofu.org/a/x" {\n  hashes = []\n}\n']}, {}, 1,
         "could not read the lock files: components/aws/x/.terraform.lock.hcl: provider "
         "registry.opentofu.org/a/x locks no version"),
        ("a scan that fails", {"a/broken": {"1.0.0": (30, None, GH)}},
         one("a/broken", "1.0.0"), {}, 1, "govulncheck on terraform-provider-broken_v1.0.0 exited 2"),
        ("a release not on GitHub", {"a/far": {"1.0.0": (30, F1, "example.com")}},
         one("a/far", "1.0.0"), {}, 1, "is not a GitHub release asset"),
        ("a provider the registry does not have", {}, one("a/gone", "1.0.0"), {}, 1,
         "could not be checked: GET https://registry.opentofu.org/v1/providers/a/gone/1.0.0/download"),
        ("a provider from another registry", {}, {LOCK: [("x", "1.0.0")]}, {}, 1, "is not a registry.opentofu.org"),
        ("too few providers", {"a/kept": {"1.0.0": (30, {}, GH)}}, one("a/kept", "1.0.0"),
         {"min_providers": 2}, 1, "refuses to report a pass"),
        ("the job summary", {"a/kept": {"1.0.0": (30, F1, GH)}}, one("a/kept", "1.0.0"),
         {"summary": True}, 0, "SUMMARY FILE:\n## Locked providers"),
    ]


def self_test(planted=None, meta: bool = True) -> int:
    failures: list[str] = []
    planted = cases() if planted is None else planted
    for name, releases, locks, kwargs, want, says in planted:
        kwargs = dict(kwargs)
        overrides = kwargs.pop("overrides", None)
        status, output, _ = run_case(releases, locks, overrides, **kwargs)
        if status != want or says not in output:
            failures.append(f"{name}: exit {status}, wanted {want} with {says!r}\n"
                            + "".join(f"      {line}\n" for line in output.splitlines()[-8:]))
    # A provider version locked in two files is checked once; two versions are two.
    rel = {"a/dup": {"1.0.0": (30, {}, GH), "1.1.0": (30, {}, GH)}}
    for locks, scans in (({LOCK: [("a/dup", "1.0.0")], "modules/aws/y/.terraform.lock.hcl": [("a/dup", "1.0.0")]}, 1),
                         ({LOCK: [("a/dup", "1.0.0")], "modules/aws/y/.terraform.lock.hcl": [("a/dup", "1.1.0")]}, 2)):
        status, output, world = run_case(rel, locks)
        if status != 0 or len(world.scans) != scans:
            failures.append(f"{len(locks)} lock files: {len(world.scans)} scan(s), wanted {scans}")
    # A provider with no findings is never dated: no GitHub call.
    _, _, world = run_case({"a/clean": {"1.0.0": (900, {}, GH)}}, {LOCK: [("a/clean", "1.0.0")]})
    if any(u.startswith(GITHUB_API) for u in world.fetched):
        failures.append("a provider with no findings was dated through the GitHub API")
    failures += real_world_checks()
    for args, want in ((["--bogus"], 2), (["--db"], 2)):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            status = cli(args)
        if status != want:
            failures.append(f"arguments {args}: exit {status}, wanted {want}")
    if meta:
        # A self-test over a case it gets wrong must fail, or it proves nothing.
        wrong = [("abandonment expected to pass", {"a/stale": {"1.0.0": (400, F1, GH)}},
                  {LOCK: [("a/stale", "1.0.0")]}, {}, 0, "listed")]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            if self_test(wrong, meta=False) == 0:
                failures.append("a self-test whose case expects an abandoned provider to pass did not fail")
    if failures:
        print("provider-vulns.py --self-test FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print(f"provider-vulns.py --self-test: {len(planted)} case(s), deduplication, the network and "
          f"scanner layers, and a self-test over a wrong case behave as the rules say.")
    return 0


def real_world_checks() -> list[str]:
    """The network and scanner layers, against stubs of what they call."""
    failures: list[str] = []
    world = World(db="file:///probe-db", govulncheck="probe-govulncheck")
    world.token = "probe-token"

    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def http_error(code: int) -> urllib.error.HTTPError:
        return urllib.error.HTTPError("u", code, "probe", {}, None)

    sequences = [
        ("a 500 then a body", [http_error(500), Response(b"ok")], b"ok", 2),
        ("a refused connection then a body", [urllib.error.URLError("refused"), Response(b"ok")], b"ok", 2),
        ("a 404 is not retried", [http_error(404)], None, 1),
        ("a 429 is retried", [http_error(429), http_error(429), http_error(429)], None, 3),
    ]
    for name, outcomes, want, calls in sequences:
        seen: list[urllib.request.Request] = []

        def opener(request, timeout, _outcomes=list(outcomes), _seen=seen):
            _seen.append(request)
            outcome = _outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        with mock.patch.object(urllib.request, "urlopen", opener), mock.patch.object(time, "sleep"):
            try:
                got = world.fetch(f"{GITHUB_API}/repos/o/r/releases/tags/v1")
            except CheckError:
                got = None
        if got != want or len(seen) != calls:
            failures.append(f"fetch, {name}: got {got!r} after {len(seen)} call(s), wanted {want!r} "
                            f"after {calls}")
        elif seen and seen[0].get_header("Authorization") != "Bearer probe-token":
            failures.append(f"fetch, {name}: the GitHub API request carried no token")

    def completed(code: int, stdout: str = "", stderr: str = "") -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess([], code, stdout, stderr)

    stream = (json.dumps({"config": {}}) + "\n"
              + json.dumps({"finding": {"osv": "GO-1", "trace": [{"module": "m", "function": "F"}]}})
              + json.dumps({"finding": {"osv": "GO-2", "trace": [{"module": "m"}]}}) + "\n")
    runs = [
        ("a scan with one linked finding", completed(0, stream), {"GO-1": "m"}),
        ("a scan that exits 2", completed(2, "", "not a file"), None),
        ("a scanner that is not installed", FileNotFoundError("probe-govulncheck"), None),
        ("a scan that runs out of time", subprocess.TimeoutExpired("probe", SCAN_TIMEOUT), None),
    ]
    for name, outcome, want in runs:
        calls: list[list[str]] = []

        def runner(cmd, *args, _outcome=outcome, _calls=calls, **kwargs):
            _calls.append(cmd)
            if isinstance(_outcome, Exception):
                raise _outcome
            return _outcome

        with mock.patch.object(subprocess, "run", runner):
            try:
                got = world.scan(Path("/probe/terraform-provider-x"))
            except CheckError:
                got = None
        if got != want or not calls or "-db" not in calls[0]:
            failures.append(f"scan, {name}: got {got!r}, wanted {want!r}, ran {calls}")
    return failures


def cli(args: list[str]) -> int:
    if args == ["--self-test"]:
        return self_test()
    db = None
    if args[:1] == ["--db"] and len(args) == 2:
        db, args = args[1], []
    if args:
        print("usage: provider-vulns.py [--self-test | --db URL]", file=sys.stderr)
        return 2
    return main(World(db=db))


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
