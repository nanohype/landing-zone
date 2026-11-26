#!/usr/bin/env python3
"""No shell script or workflow step makes a network call that can hang forever.

WHY THIS EXISTS

`|| true` converts a FAILURE into a continue and does nothing about a HANG. A
remote that accepts the TCP connection and then stalls blocks the caller
indefinitely — and in scripts/e2e.sh the caller is a teardown holding an EKS
cluster, NAT gateways and Graviton nodes that keep billing while it waits.

The tools differ in what they do by default, which is why this cannot be left to
habit:

  kubectl        unbounded by default. This is the one that bites.
  curl           unbounded by default without --max-time.
  git            unbounded; no deadline flag, so it needs an external `timeout`.
  go build       unbounded on a module fetch; same.
  tofu init      downloads providers and modules, with no deadline flag; same.
  tflint --init  downloads the ruleset through an HTTP client with no timeout,
                 which bounds only the dial and the TLS handshake; same.
  aws            bounded by its own default connect and read timeouts.

A workflow job's `timeout-minutes` does not answer this. It bounds the job: a
call that stalls holds the runner for the job's whole budget, and the failure
reads as a job timeout rather than as the call that stopped.

WHAT IT CHECKS

Every invocation of an unbounded-by-default tool, in a tracked shell script or in
the `run:` of a workflow step, is bounded by one of four mechanisms: an explicit
deadline flag on the call, an external `timeout` prefix, a shell function of the
same name that injects one (the wrapper pattern — which is preferred, because it
makes a call that forgets impossible rather than merely detectable), or, in a
workflow, a `timeout-minutes` on the step that makes the call.

The wrapper is what a per-call check cannot see on its own, so it is looked for
first: a script defining `kubectl() { ... --request-timeout ... }` has bounded
every kubectl call in it, including the ones written after the wrapper.

A call is found where a command starts: at the start of a line or after `|`,
`;`, `&`, `(`, a backtick or `$(`, past any variable assignments and any `env`,
`command`, `exec` or `timeout` in front of the tool. A tool run through another
program (`xargs`, `sudo`, `nice`) is not found. A line ending in a backslash
continues onto the next, so a deadline flag on a continuation line counts. The
call runs to the end of its command (the first `|`, `;`, `&`, `)` or backtick
outside quotes), so a deadline flag on another command does not bound it. Only
the calls that reach the network are held to a deadline: git and helm calls
other than the local subcommands named in LOCAL, and go, tofu and tflint calls
on the subcommands named in NETWORK.

Workflows are read with a YAML parser, because a step's `run:` and its
`timeout-minutes` are related only through the structure. A workflow the parser
cannot read fails the check rather than passing unread.

VIEW

Comment bodies are blanked. A comment mentioning kubectl is not a call, and prose
about deadlines must not satisfy a check about deadlines — which is the exact
shape this gate is here to prevent, since the comment claiming every call was
bounded is what made the gap invisible.

`--self-test` runs the rules over planted scripts, workflows and repositories,
each with the exit status and the message it must produce.

Exit 0 = every call is bounded. Exit 1 = an unbounded call, an unreadable
workflow, or nothing read. Exit 2 = usage.
"""

from __future__ import annotations

import contextlib
import io
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from _repo import repo_is_visible

try:
    import yaml
except ImportError:  # pragma: no cover - environment without pyyaml
    print(
        "FAIL: PyYAML is not available, so this check cannot parse the workflows. "
        "It refuses to report a pass rather than skip: a check that silently does "
        "nothing when a dependency is missing is the failure it exists to prevent.",
        file=sys.stderr,
    )
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent

# The SECOND of two floors, and they are deliberately separate because they are
# different kinds of claim:
#
#   UNCONDITIONAL (repo_is_visible, in _repo.py) — the tracked set holds
#     something other than the gates themselves. A law about ANY tree, and the
#     half that catches a scripts-only checkout however the count falls.
#   REPO-ONLY (below) — this repository tracks several times ten shell scripts,
#     so a scan seeing fewer than ten saw almost nothing. True of THIS tree, not
#     a law.
#
# Collapsing them into one number is what makes a floor reject a known-good
# fixture: a small legitimate tree fails the repo-only count while satisfying
# the unconditional rule, and the gate then reads as broken rather than as
# out of scope.
MIN_SCRIPTS = 10

# tool -> the flag that bounds it on the call itself, if it has one.
UNBOUNDED = {
    "kubectl": "--request-timeout",
    "curl": "--max-time",
    "git": None,
    "helm": "--timeout",
    "go": None,
    "tofu": None,
    "tflint": None,
}

# Subcommands of git and helm that reach no network, so a deadline would bound
# nothing. Every other git or helm call is a network call. Reporting a local call
# as an unbounded network call is the false positive that gets a gate switched
# off.
LOCAL = {
    "git": {"add", "commit", "rm", "checkout", "diff", "status", "log", "config", "init",
            "rev-parse", "ls-files"},
    "helm": {"template", "show", "lint"},
}

# The subcommands of go, tofu and tflint that reach the network. Their other
# calls (`go vet`, `tofu validate`, a tflint lint run) read only the tree.
NETWORK = {
    "go": {("build",), ("get",), ("install",), ("run",), ("test",), ("mod", "download"),
           ("mod", "tidy")},
    "tofu": {("init",)},
}

# Variable assignments and the prefixes that run the next word as the command.
# `timeout` is among them so that a bounded call is still FOUND, then counted as
# bounded, rather than passed over as if it were not a call.
PREFIX = (
    r"(?:(?:[A-Za-z_][A-Za-z0-9_]*=\S*|env|command|exec"
    r"|timeout(?:\s+-{1,2}[A-Za-z-]+(?:[= ]\S+)?)*\s+[0-9.]+[smhd]?)\s+)*"
)
CALL = re.compile(
    r"(?:^|[|;&(`]|\$\()\s*(?P<prefix>" + PREFIX + r")"
    r"(?P<tool>" + "|".join(UNBOUNDED) + r")(?=\s|$)"
)


def blank_comment_bodies(text: str) -> str:
    """Blank comment interiors in SHELL, preserving length and line breaks.

    Deliberately NOT the shared HCL view in scripts/_hcl.py, which treats `//`
    as a comment opener. Shell has no `//` comment and `//` appears in live code
    (a `sed 's//x/'`, a doubled path separator), so importing the shared helper
    here would blank real code.

    Said out loud because a helper that several gates share invites unifying the
    stragglers onto it, and that edit is correct everywhere except here.
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
        elif c == "#":
            while i < len(text) and text[i] != "\n":
                out.append(" ")
                i += 1
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)


def logical_lines(code: str) -> list[tuple[int, str]]:
    """(line number of its first line, text) for each line, continuations joined."""
    out: list[tuple[int, str]] = []
    first, parts = 0, []
    for n, line in enumerate(code.splitlines(), 1):
        if not parts:
            first = n
        if line.endswith("\\"):
            parts.append(line[:-1])
            continue
        parts.append(line)
        out.append((first, " ".join(parts)))
        parts = []
    if parts:
        out.append((first, " ".join(parts)))
    return out


def call_text(line: str, start: int) -> str:
    """The command that starts at `start`, up to the first separator outside quotes.

    The separators are `|`, `;`, `&`, `)` and a backtick. The `&` of a redirection
    (`2>&1`, `&>`) and the `)` closing a `$( )` opened inside the command do not
    end it, so a deadline flag written after either still belongs to the call. A
    flag on another command on the same line does not.
    """
    quote, depth, i = None, 0, start
    while i < len(line):
        c = line[i]
        if quote:
            if c == "\\" and quote == '"':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "\\":
            i += 2
            continue
        elif line.startswith("$(", i):
            depth += 1
            i += 2
            continue
        elif c == ")" and depth:
            depth -= 1
        elif c == "&" and (line[i - 1] == ">" or line[i + 1 : i + 2] == ">"):
            pass
        elif c in "|;&)`":
            break
        i += 1
    return line[start:i]


def reaches_network(tool: str, words: list[str]) -> bool:
    """Whether a call, split into words from the tool's name on, is a network call."""
    if tool == "tflint":
        return "--init" in words
    args = words[1:]
    # Global flags come before the subcommand: `git -C <dir> checkout`,
    # `git -c user.name=x commit`, `tofu -chdir=<dir> init`.
    while args and args[0].startswith("-"):
        args = args[2:] if args[0] in ("-C", "-c") else args[1:]
    if tool in LOCAL:
        return not args or args[0] not in LOCAL[tool]
    if tool in NETWORK:
        return any(tuple(args[: len(sub)]) == sub for sub in NETWORK[tool])
    return True


def unbounded_calls(code: str, step_bounded: bool = False) -> tuple[int, list[tuple[int, str]]]:
    """(network calls checked, [(line, text)] of the unbounded ones) in one script.

    `code` has its comment bodies blanked. `step_bounded` is True for a workflow
    step whose `timeout-minutes` bounds every call it makes. A tool behind a
    wrapper function is bounded by construction and not counted.
    """
    wrapped = {
        tool
        for tool, flag in UNBOUNDED.items()
        if flag and re.search(rf"^{tool}\(\)\s*\{{[^}}]*{re.escape(flag)}", code, re.M)
    }
    checked = 0
    found: list[tuple[int, str]] = []
    for n, line in logical_lines(code):
        for m in CALL.finditer(line):
            tool = m.group("tool")
            call = call_text(line, m.start("tool"))
            if tool in wrapped or not reaches_network(tool, call.split()):
                continue
            checked += 1
            flag = UNBOUNDED[tool]
            if step_bounded or "timeout" in m.group("prefix").split() or (flag and flag in call):
                continue
            found.append((n, line.strip()))
    return checked, found


def _get(node: yaml.Node | None, key: str) -> yaml.Node | None:
    if isinstance(node, yaml.MappingNode):
        for k, v in node.value:
            if isinstance(k, yaml.ScalarNode) and k.value == key:
                return v
    return None


def workflow_steps(text: str) -> list[tuple[int, str, bool, bool]]:
    """(line of the step's `run:`, script, literal block, has timeout-minutes) per step.

    Raises yaml.YAMLError for a file the parser cannot read. A literal block (`|`)
    keeps its lines as written, so a call in it is reported at its own line; any
    other scalar is reported at the line its `run:` starts on.
    """
    root = yaml.compose(text)
    jobs = _get(root, "jobs")
    out = []
    for _, job in jobs.value if isinstance(jobs, yaml.MappingNode) else []:
        steps = _get(job, "steps")
        for step in steps.value if isinstance(steps, yaml.SequenceNode) else []:
            run = _get(step, "run")
            if isinstance(run, yaml.ScalarNode):
                out.append((run.start_mark.line + 1, run.value, run.style == "|",
                            _get(step, "timeout-minutes") is not None))
    return out


def tracked(root: Path, *patterns: str) -> list[str]:
    return subprocess.run(
        ["git", "-C", str(root), "ls-files", *patterns],
        capture_output=True, text=True, check=True,
    ).stdout.split()


def main(root: Path = ROOT, min_scripts: int = MIN_SCRIPTS) -> int:
    scripts = tracked(root, "*.sh")
    # Two preconditions, and they answer different questions. The first asks
    # whether the PATTERN matched; the second asks whether the REPOSITORY is
    # here. A tree holding nothing but the gate scripts satisfies the first
    # using this gate's own file and fails the second, which is exactly the
    # shape that reported a pass over an absent tree.
    if not scripts:
        print(
            "FAIL: no shell scripts found. The scan could not see the tree; "
            "refusing to report a pass.",
            file=sys.stderr,
        )
        return 1
    visible, why = repo_is_visible(root)
    if not visible:
        print(f"FAIL: {why}", file=sys.stderr)
        return 1
    if len(scripts) < min_scripts:
        print(
            f"FAIL: found only {len(scripts)} shell script(s), below the "
            f"{min_scripts} floor. The scan saw almost nothing, which is what a wrong "
            f"working directory or a broken pathspec looks like from in here. "
            f"Refusing to report a pass over a collapsed denominator.",
            file=sys.stderr,
        )
        return 1
    workflows = tracked(root, ".github/workflows/*.yml", ".github/workflows/*.yaml")
    if not workflows:
        print(
            "FAIL: no workflow found under .github/workflows/. The scan could not see "
            "them; refusing to report a pass.",
            file=sys.stderr,
        )
        return 1

    unbounded: list[str] = []
    unreadable: list[str] = []
    checked = 0

    for rel in scripts:
        n_checked, found = unbounded_calls(blank_comment_bodies((root / rel).read_text()))
        checked += n_checked
        unbounded += [f"  {rel}:{n}: {text[:100]}" for n, text in found]

    steps = 0
    for rel in workflows:
        try:
            parsed = workflow_steps((root / rel).read_text())
        except yaml.YAMLError as e:
            unreadable.append(f"  {rel}: {str(e).splitlines()[0]}")
            continue
        for line, script, literal, step_bounded in parsed:
            steps += 1
            n_checked, found = unbounded_calls(blank_comment_bodies(script), step_bounded)
            checked += n_checked
            # A literal block's first line follows the line its `run:` is on.
            unbounded += [f"  {rel}:{line + n if literal else line}: {text[:100]}"
                          for n, text in found]

    if unreadable:
        print("Workflow(s) the YAML parser could not read:\n", file=sys.stderr)
        print("\n".join(unreadable), file=sys.stderr)
        print("\nAn unread workflow is unchecked, so this refuses to report a pass.",
              file=sys.stderr)
        return 1
    if not steps:
        print(
            f"FAIL: read {len(workflows)} workflow(s) and found no step that runs a "
            f"script. The scan saw no `run:` to check; refusing to report a pass.",
            file=sys.stderr,
        )
        return 1
    if unbounded:
        print("Network call(s) with no deadline:\n", file=sys.stderr)
        print("\n".join(unbounded), file=sys.stderr)
        print(
            "\n`|| true` handles a failure and does nothing about a hang. Bound the "
            "call with its own deadline flag, prefix it with `timeout`, define a "
            "wrapper function for the tool, or, in a workflow, give the step a "
            "`timeout-minutes`. The wrapper is best, because it makes a call that "
            "forgets impossible rather than merely detectable.",
            file=sys.stderr,
        )
        return 1

    print(
        f"✓ every network call in a shell script or workflow step is bounded "
        f"({checked} unwrapped call(s) checked across {len(scripts)} script(s) and "
        f"{steps} workflow step(s); wrapped tools are bounded by construction)"
    )
    return 0


# --- self-test --------------------------------------------------------------

PROBE = "scripts/probe.sh"
PROBE_WORKFLOW = ".github/workflows/probe.yml"
QUIET_SCRIPT = "#!/usr/bin/env bash\necho ok\n"


def workflow(*steps: str) -> str:
    """A one-job workflow; the job carries a timeout, so no step inherits a bound."""
    return (
        "name: probe\n"
        "on: push\n"
        "jobs:\n"
        "  probe:\n"
        "    runs-on: ubuntu-latest\n"
        "    timeout-minutes: 10\n"
        "    steps:\n" + "".join(steps)
    )


QUIET_WORKFLOW = workflow("      - run: echo ok\n")


def script(*lines: str) -> dict[str, str]:
    return {PROBE: "#!/usr/bin/env bash\n" + "".join(line + "\n" for line in lines)}


def steps(*lines: str) -> dict[str, str]:
    return {PROBE_WORKFLOW: workflow(*lines)}


def run_on(files: dict[str, str], min_scripts: int = 1) -> tuple[int, str]:
    """(exit status, output) of main() over a repository holding `files`.

    The repository holds a README, a quiet script and a quiet workflow unless
    `files` replaces them; a path mapped to None is left out.
    """
    tree = {"README.md": "probe\n", PROBE: QUIET_SCRIPT, PROBE_WORKFLOW: QUIET_WORKFLOW}
    tree.update(files)
    with tempfile.TemporaryDirectory(prefix="deadlines-self-test-") as tmp:
        root = Path(tmp)
        for rel, text in tree.items():
            if text is not None:
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text(text)
        subprocess.run(["git", "init", "-q", str(root)], check=True, timeout=60)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, timeout=60)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            status = main(root=root, min_scripts=min_scripts)
        return status, out.getvalue()


def cases() -> list[tuple[str, dict, int, str, int]]:
    """(name, files, expected status, text the output must hold, min_scripts)."""
    ok = "✓ every network call"
    call = f"{PROBE}:2: "
    step = f"{PROBE_WORKFLOW}:8: "
    return [
        # Shell scripts: each tool, unbounded and bounded.
        ("kubectl with no deadline", script("kubectl get pods -A"), 1,
         call + "kubectl get pods -A", 1),
        ("kubectl with --request-timeout", script("kubectl get pods --request-timeout=10s"), 0,
         ok, 1),
        ("kubectl behind a wrapper",
         script('kubectl() { command kubectl --request-timeout=10s "$@"; }', "kubectl get pods"),
         0, "0 unwrapped call(s)", 1),
        ("kubectl named only in a comment", script("# kubectl get pods -A"), 0, ok, 1),
        ("curl with no --max-time", script("curl -fsSL https://example.invalid"), 1,
         call + "curl", 1),
        ("curl with --max-time", script("curl -fsSL --max-time 30 https://example.invalid"), 0,
         ok, 1),
        ("git push with no timeout", script("git push -q origin HEAD:main"), 1,
         call + "git push", 1),
        ("git push under timeout", script("timeout 120 git push -q origin HEAD:main"), 0,
         "1 unwrapped call(s)", 1),
        ("git commit after a global flag is local",
         script('git -C "$dir" -c user.name=x commit -q -m probe'), 0, "0 unwrapped call(s)", 1),
        ("a local git call does not excuse the network call beside it",
         script('(git ls-files >/dev/null && tofu init -backend=false)'), 1,
         call + "(git ls-files", 1),
        ("helm template is local", script("helm template probe ./chart"), 0,
         "0 unwrapped call(s)", 1),
        ("helm upgrade with no --timeout", script("helm upgrade --install probe ./chart"), 1,
         call + "helm upgrade", 1),
        ("helm upgrade with --timeout", script("helm upgrade --install probe ./chart --timeout 5m"),
         0, ok, 1),
        ("go build with no timeout", script("go build -o /tmp/probe ."), 1, call + "go build", 1),
        ("go mod download with no timeout", script("go mod download"), 1, call + "go mod", 1),
        ("go build under timeout with options", script("timeout -k 5 300 go build ."), 0,
         "1 unwrapped call(s)", 1),
        ("go vet reaches no network", script("go vet ./..."), 0, "0 unwrapped call(s)", 1),
        ("tofu init with no timeout", script('(cd "$dir" && tofu init -backend=false)'), 1,
         call + '(cd "$dir" && tofu init', 1),
        ("tofu -chdir init with no timeout", script("tofu -chdir=components/aws/x init"), 1,
         call + "tofu -chdir", 1),
        ("tofu init under timeout", script("timeout 10m tofu init -backend=false"), 0,
         "1 unwrapped call(s)", 1),
        ("tofu validate reaches no network", script("tofu validate"), 0, "0 unwrapped call(s)", 1),
        ("tflint --init with no timeout", script("tflint --config x.hcl --init"), 1,
         call + "tflint --config", 1),
        ("a tflint lint run reaches no network", script("tflint --recursive --config x.hcl"), 0,
         "0 unwrapped call(s)", 1),
        ("an assignment in front of the tool", script("TF_LOG=debug tofu init"), 1,
         call + "TF_LOG=debug", 1),
        ("env in front of the tool", script("env KUBECONFIG=/tmp/k kubectl get ns"), 1,
         call + "env KUBECONFIG", 1),
        ("a call inside $( )", script('ns="$(kubectl get ns -o name)"'), 1, call + "ns=", 1),
        ("the deadline flag on a continuation line",
         script("kubectl get pods \\", "  --request-timeout=10s"), 0, "1 unwrapped call(s)", 1),
        ("an unbounded call reported at its first line",
         script("kubectl get pods \\", "  -A"), 1, call + "kubectl get pods", 1),
        ("a deadline on an earlier command does not bound a later one",
         script("kubectl get ns --request-timeout=5s && kubectl get pods"), 1,
         call + "kubectl get ns", 1),
        ("a deadline on a later command does not bound an earlier one",
         script("kubectl get pods; kubectl get ns --request-timeout=5s"), 1,
         call + "kubectl get pods;", 1),
        ("a separator inside quotes does not end the call",
         script("kubectl get pods -o jsonpath='{.items[*]};a|b&c' --request-timeout=5s"), 0,
         "1 unwrapped call(s)", 1),
        ("a redirection does not end the call",
         script('curl -fsS "$url" 2>&1 --max-time 30'), 0, "1 unwrapped call(s)", 1),
        ("a $( ) inside the call does not end it",
         script("kubectl get pods -n $(cat ns) --request-timeout=5s"), 0,
         "1 unwrapped call(s)", 1),
        # Workflows: the step's timeout-minutes counts, the job's does not.
        ("a step with only its job's timeout-minutes",
         steps("      - run: tflint --init --config .tflint-aws.hcl\n"), 1,
         step + "tflint --init", 1),
        ("a step with its own timeout-minutes",
         steps("      - timeout-minutes: 5\n        run: tflint --init --config .tflint-aws.hcl\n"),
         0, "1 unwrapped call(s)", 1),
        ("timeout inside a step's script", steps("      - run: timeout 10m tofu init\n"), 0,
         "1 unwrapped call(s)", 1),
        ("a call in a literal block reported at its own line",
         steps("      - run: |\n          set -e\n          tofu init -backend=false\n"), 1,
         f"{PROBE_WORKFLOW}:10: tofu init", 1),
        ("a quoted script reported at its run: line", steps('      - run: "tofu init"\n'), 1,
         step + "tofu init", 1),
        ("a wrapper inside a step's script",
         steps("      - run: |\n"
               '          curl() { command curl --max-time 30 "$@"; }\n'
               "          curl -fsSL https://example.invalid\n"), 0, "0 unwrapped call(s)", 1),
        # Preconditions: each refuses to report a pass over what it could not read.
        ("no shell script tracked", {PROBE: None}, 1, "no shell scripts found", 1),
        ("only the gates are tracked",
         {"README.md": None, PROBE_WORKFLOW: None, "scripts/README": "probe\n"}, 1,
         "is under scripts/", 1),
        ("fewer scripts than the floor", {}, 1, "below the 2 floor", 2),
        ("no workflow tracked", {PROBE_WORKFLOW: None}, 1, "no workflow found", 1),
        ("a workflow the parser cannot read", {PROBE_WORKFLOW: "jobs: [\n"}, 1,
         f"{PROBE_WORKFLOW}: while parsing", 1),
        ("no workflow step runs a script",
         steps("      - uses: actions/checkout@v4\n"), 1, "found no step that runs a script", 1),
        ("a workflow with no jobs", {PROBE_WORKFLOW: "name: probe\non: push\n"}, 1,
         "found no step that runs a script", 1),
        ("everything bounded", {}, 0, ok, 1),
    ]


def self_test() -> int:
    failures = []
    planted = cases()
    for name, files, want, says, min_scripts in planted:
        status, output = run_on(files, min_scripts)
        if status != want or says not in output:
            failures.append(f"{name}: exit {status}, wanted {want} with \"{says}\"\n"
                            + "".join(f"      {line}\n" for line in output.splitlines()[-6:]))
    # Each tool the check knows has a planted call it must report and one it must
    # pass, so a tool added to UNBOUNDED without cases fails here.
    for tool in UNBOUNDED:
        for want in (0, 1):
            if not any(w == want and any(re.search(rf"\b{tool}\b", t or "") for t in f.values())
                       for _, f, w, _, _ in planted):
                failures.append(f"no case plants a{' bounded' if want == 0 else 'n unbounded'} "
                                f"{tool} call")
    if failures:
        print("check-network-deadlines.py --self-test FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print(f"check-network-deadlines.py --self-test: {len(planted)} case(s) across "
          f"{len(UNBOUNDED)} tool(s) behave as the rules say.")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:]:
        print("usage: check-network-deadlines.py [--self-test]", file=sys.stderr)
        sys.exit(2)
    sys.exit(main())
