"""Shared precondition: the gate is looking at this repository.

Not a gate: the filename is outside the `check-*` glob that `task gates`, CI and
the positive-control floor discover, so it is imported by the gates that read
shell scripts and never run as one. `_repo.py --self-test` proves each refusal
below; `task gates` and CI's coverage job run it, as they run every script under
scripts/ that takes `--self-test`.

WHY THIS EXISTS

A gate that reports on a tree it cannot see reports a pass. Guarding that with
"at least one file matched" is not enough, because the count answers a different
question: it says the PATTERN matched something, not that the REPOSITORY is
there. A tree holding nothing but the gate scripts satisfies "at least one shell
script" using the gates' own files, and every shell-reading gate then passes
over a repository that is absent.

Printing the denominator does not close this either. `0 unwrapped call(s)
checked across 2 script(s)` is an accurate report of a vacuous scan, and it was
printed immediately before an exit 0.

WHAT IT CHECKS

That the tracked set contains something other than `scripts/`. It is exact
rather than a threshold: a repository is present or it is not, and a number
chosen today drifts as the tree grows.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock


def repo_is_visible(root: Path) -> tuple[bool, str]:
    """(True, "") when the tracked tree is more than the gate scripts.

    Returns the reason rather than raising, so a caller reports it in its own
    voice — a gate's refusal should read like that gate, not like a library.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", str(root), "ls-files"],
            capture_output=True, text=True, check=False, timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as e:
        return False, (
            f"`git ls-files` could not run ({type(e).__name__}), so the tracked set "
            "could not be read. This gate reads the repository through git; without "
            "it there is nothing to check rather than nothing to report."
        )
    if proc.returncode != 0:
        return False, (
            "`git ls-files` failed, so the tracked set could not be read. This "
            "gate reads the repository through git; without it there is nothing "
            "to check rather than nothing to report."
        )
    tracked = [p for p in proc.stdout.split("\n") if p]
    if not tracked:
        return False, "the tracked set is empty — this is not a checkout of the repository."
    outside = [p for p in tracked if not p.startswith("scripts/")]
    if not outside:
        return False, (
            f"every one of the {len(tracked)} tracked file(s) is under scripts/, "
            f"so the only thing here is the gates themselves. A scan of this tree "
            f"reports on nothing and would exit 0 saying so."
        )
    return True, ""


# --- self-test ------------------------------------------------------------------

# Trees git is asked to list: (name, what git tracks, or None for a directory that is
# not a checkout, words the refusal says, or None for a tree that must be accepted).
CASES = [
    ("a directory that is not a git checkout", None, "`git ls-files` failed"),
    ("a checkout that tracks nothing", (), "the tracked set is empty"),
    ("a checkout that tracks only the gate scripts", ("scripts/check-x.sh",),
     "is under scripts/"),
    ("a checkout that tracks more than the gate scripts", ("scripts/check-x.sh", "README.md"),
     None),
]
# git failing to list that last checkout: (name, what running git raises, or None for a
# git that outlasts the timeout the call sets, words the refusal says).
GIT_FAILURES = [
    ("git is not installed", FileNotFoundError(2, "No such file or directory", "git"),
     "could not run (FileNotFoundError)"),
    ("git ls-files does not finish within its timeout", None, "could not run (TimeoutExpired)"),
]


def expect(ok: bool, message: str) -> list[str]:
    """[message] when a case failed, else nothing."""
    return [] if ok else [message]


def _checkout(root: Path, tracks) -> None:
    """root as a directory, and with tracks not None a checkout git tracks them in."""
    root.mkdir()
    if tracks is None:
        return
    subprocess.run(["git", "init", "-q", str(root)], check=True, capture_output=True, timeout=60)
    for rel in tracks:
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text("x\n")
    if tracks:
        subprocess.run(["git", "-C", str(root), "add", *tracks], check=True,
                       capture_output=True, timeout=60)


def _outlasting_git(timeouts: list):
    """subprocess.run for a git that never finishes, recording in timeouts the timeout each
    call set: it raises as subprocess.run does once that timeout passes, where a call that
    set none would wait for ever."""
    def run(args, **kwargs):
        timeouts.append(kwargs.get("timeout"))
        raise subprocess.TimeoutExpired(args, kwargs.get("timeout") or 0)
    return run


def self_test(cases=tuple(CASES), git_failures=tuple(GIT_FAILURES), meta: bool = True) -> int:
    """0 when repo_is_visible refuses each tree it must, in its words, and accepts the one
    it must; 1 otherwise. With meta, a self-test over a failing case must fail too."""
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="repo-visible-") as tmp, \
            mock.patch.dict(os.environ, {"GIT_CEILING_DIRECTORIES": tmp}):
        for n, (name, tracks, says) in enumerate(cases):
            root = Path(tmp) / f"case-{n}"
            _checkout(root, tracks)
            got = repo_is_visible(root)
            failures += expect(got == (True, "") if says is None else
                               (not got[0] and says in got[1]),
                               f"{name}: returned {got!r}, not "
                               + ("(True, '')" if says is None else f"a refusal saying {says!r}"))
        tracked = Path(tmp) / "tracked"
        _checkout(tracked, ("scripts/check-x.sh", "README.md"))
        for name, raised, says in git_failures:
            timeouts: list = []
            with mock.patch.object(subprocess, "run",
                                   side_effect=raised or _outlasting_git(timeouts)):
                got = repo_is_visible(tracked)
            bounded = raised is not None or (bool(timeouts) and None not in timeouts)
            failures += expect(bounded and not got[0] and says in got[1],
                               f"{name}: returned {got!r}"
                               + ("" if bounded else ", and git ran with no timeout"))
    if meta:
        # The reporter, checked without itself, and a self-test over a failing case.
        failures += ["expect() does not report a failed case"] * (expect(False, "x") != ["x"])
        with mock.patch("sys.stderr"), mock.patch("sys.stdout"):
            failing = self_test((("planted", None, "words no refusal says"),), (), meta=False)
        failures += expect(failing == 1, "a self-test over a failing case passed")
        proc = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--no-such-flag"],
                              capture_output=True, text=True, timeout=60, check=False)
        failures += expect(proc.returncode == 2 and "usage:" in proc.stderr,
                           f"an argument it does not take: exited {proc.returncode}, not 2")
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    if failures:
        print(f"_repo self-test FAILED: {len(failures)} problem(s)", file=sys.stderr)
        return 1
    print(f"_repo self-test passed ({len(cases)} trees refused or accepted as they must be, "
          f"and {len(git_failures)} ways git fails to list a checkout refused"
          + (", a self-test over a failing case fails, and an argument it does not take is "
             "refused" if meta else "") + ").")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] != ["--self-test"]:
        print("usage: _repo.py --self-test (it is imported by the gates, not run)",
              file=sys.stderr)
        sys.exit(2)
    sys.exit(self_test())
