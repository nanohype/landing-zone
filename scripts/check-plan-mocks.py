#!/usr/bin/env python3
"""A plan this repository applies reads no mock output.

deploy.yml plans one component, saves the plan, and applies exactly that file
once the environment admits the apply. A saved plan fixes every input when it
is made, so what a dependency handed the plan is what the apply writes. That
includes a mock. Terragrunt hands a dependency's mock_outputs to every command
its mock_outputs_allowed_terraform_commands admits, in place of a dependency
with no state, and, with mock_outputs_merge_strategy_with_state = "shallow", in
place of any output the dependency's state lacks. The apply cannot tell a mock
from a real output: `vpc-mock` reaches the EC2 API as a VPC id, and a mock ARN
in a policy document is accepted as written.

Mocks are wanted wherever nothing is applied: `validate`, the credential-less
render, CI's plan of the development leaves, and deploy.yml's component=all
plan, which plans every unit before any is applied. So a dependency admits
mocks to `plan` only while MOCK_OUTPUTS_IN_PLAN is "true", its default, and a
step that saves a plan sets it to "false".

WHAT IT CHECKS

Every `dependency` block under live/ that declares mock_outputs:

  - declares mock_outputs_allowed_terraform_commands, on one line. Terragrunt
    reads a missing or empty list as every command, apply included;
  - gives it as a list that does not name plan, or as

        get_env("MOCK_OUTPUTS_IN_PLAN", "true") == "true" ? [...] : [...]

    whose second list does not name plan;
  - names apply in neither list.

Every workflow step that saves a plan (a line running `plan` with `-out`):

  - sets MOCK_OUTPUTS_IN_PLAN to "false" in its env;
  - changes it nowhere in its script, except as the prefix of a command that
    saves no plan.

It refuses to report a pass over fewer than 15 dependency blocks with mocks, or
over no step that saves a plan: either means the scan stopped seeing the tree.

Exit 0 = every dependency and every plan-saving step holds to this. Exit 1 =
one does not, a file could not be read, or the scan saw too little. Exit 2 =
usage, PyYAML is missing, or git does not track the tree.
"""

from __future__ import annotations

import contextlib
import io
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock

from _hcl import blank_comments
from _repo import repo_is_visible

try:
    import yaml
except ImportError:  # cli() reports it; CI installs PyYAML for this job
    yaml = None

ROOT = Path(__file__).resolve().parent.parent
VAR = "MOCK_OUTPUTS_IN_PLAN"
GUARD = f'get_env("{VAR}", "true") == "true"'
ATTR = "mock_outputs_allowed_terraform_commands"
# The tree has 23 dependency blocks with mocks, and deploy.yml one step that
# saves a plan. Fewer than these means the scan, not the tree, changed.
MIN_DEPENDENCIES = 15
MIN_SAVING_STEPS = 1

DEPENDENCY = re.compile(r'^dependency\s+"([^"]+)"\s*\{')
MOCKS = re.compile(r"^\s*mock_outputs\s*=")
SETTING = re.compile(rf"^\s*{ATTR}\s*=\s*(.*?)\s*$")
LIST = r"\[([^\[\]]*)\]"
LITERAL = re.compile(rf"^{LIST}$")
CONDITIONAL = re.compile(rf"^{re.escape(GUARD)}\s*\?\s*{LIST}\s*:\s*{LIST}$")
ITEMS = re.compile(r'^\s*(?:"[^"]*"\s*(?:,\s*"[^"]*"\s*)*,?)?\s*$')
SAVES = re.compile(r"\bplan\b.*?(?<![\w-])-out(?:=|\s)")
# `MOCK_OUTPUTS_IN_PLAN=x command`: an assignment that reaches that command
# alone. One followed by nothing, `;`, `&&` or `|` changes the script's own copy.
PREFIX = re.compile(rf"^\s*{VAR}=[^\s;&|]*\s+[^\s;&|]")


def tracked(root: Path, *patterns: str) -> list[str]:
    return subprocess.run(
        ["git", "-C", str(root), "ls-files", *patterns],
        capture_output=True, text=True, check=True, timeout=60,
    ).stdout.split()


def commands(inner: str) -> list[str] | None:
    """The commands a list names, or None when it holds anything but quoted strings."""
    if not ITEMS.match(inner):
        return None
    return re.findall(r'"([^"]*)"', inner)


def blocks(text: str):
    """(name, first line, lines) of each top-level dependency block, comments blanked."""
    lines = blank_comments(text).split("\n")
    i = 0
    while i < len(lines):
        m = DEPENDENCY.match(lines[i])
        if not m:
            i += 1
            continue
        depth = lines[i].count("{") - lines[i].count("}")
        j = i + 1
        while j < len(lines) and depth > 0:
            depth += lines[j].count("{") - lines[j].count("}")
            j += 1
        yield m.group(1), i + 1, lines[i:j]
        i = j


def setting_problem(value: str) -> str | None:
    """How a mock_outputs_allowed_terraform_commands value hands a mock to an applied plan."""
    if m := LITERAL.match(value):
        lists = [commands(m.group(1))]
    elif m := CONDITIONAL.match(value):
        lists = [commands(m.group(1)), commands(m.group(2))]
    else:
        return (f"is `{value}`: write it on one line, as a list that does not name plan or as "
                f"`{GUARD} ? [...] : [...]`")
    if any(names is None for names in lists):
        return f"is `{value}`, which names something other than quoted commands"
    if any(not names for names in lists):
        return "is an empty list, which terragrunt reads as every command, apply included"
    if any("apply" in names for names in lists):
        return "names apply, so an apply reads the mocks in place of the dependency's outputs"
    if "plan" in lists[-1]:
        when = "in every plan" if len(lists) == 1 else f'even when {VAR} is "false"'
        return (f"admits the mocks to plan {when}, so the plan deploy.yml saves and applies can "
                f"read one. Take plan off it when {VAR} is not \"true\": `{GUARD} ? [...] : [...]`")
    return None


def check_dependencies(root: Path) -> tuple[list[str], int]:
    findings, seen = [], 0
    for rel in tracked(root, "live/*.hcl"):
        try:
            text = (root / rel).read_text()
        except (OSError, UnicodeDecodeError) as e:
            findings.append(f"{rel}: unreadable ({type(e).__name__})")
            continue
        for name, line, body in blocks(text):
            if not any(MOCKS.match(row) for row in body):
                continue
            seen += 1
            settings = [(k, m.group(1)) for k, row in enumerate(body) if (m := SETTING.match(row))]
            if not settings:
                findings.append(f"{rel}:{line}: dependency \"{name}\" declares mock_outputs and no "
                                f"{ATTR}, which terragrunt reads as every command, apply included")
            for k, value in settings:
                if problem := setting_problem(value):
                    findings.append(f"{rel}:{line + k}: dependency \"{name}\": {ATTR} {problem}")
    return findings, seen


def steps(doc):
    """(job id, step number, step) of every step in a parsed workflow."""
    jobs = doc.get("jobs") if isinstance(doc, dict) else None
    for job_id, job in (jobs.items() if isinstance(jobs, dict) else ()):
        listed = job.get("steps") if isinstance(job, dict) else None
        for n, step in enumerate(listed if isinstance(listed, list) else (), 1):
            if isinstance(step, dict):
                yield job_id, n, step


def check_workflows(root: Path) -> tuple[list[str], int]:
    findings, saving = [], 0
    for rel in tracked(root, ".github/workflows/*.yml", ".github/workflows/*.yaml"):
        try:
            doc = yaml.safe_load((root / rel).read_text())
        except (OSError, UnicodeDecodeError, yaml.YAMLError) as e:
            findings.append(f"{rel}: unreadable ({type(e).__name__})")
            continue
        for job_id, n, step in steps(doc):
            run = step.get("run")
            script = run.splitlines() if isinstance(run, str) else []
            if not any(SAVES.search(row) for row in script):
                continue
            saving += 1
            where = f"{rel}: job '{job_id}', step '{step.get('name') or n}'"
            env = step.get("env")
            if str(env.get(VAR) if isinstance(env, dict) else None).lower() != "false":
                findings.append(f"{where} saves a plan without {VAR}: \"false\" in its env, so the "
                                f"plan reads any dependency's mocks, and an apply of it applies them")
            for k, row in enumerate(script, 1):
                if VAR not in row:
                    continue
                if SAVES.search(row):
                    findings.append(f"{where}, script line {k}: sets {VAR} on the command that "
                                    f"saves the plan")
                elif not PREFIX.match(row):
                    findings.append(f"{where}, script line {k}: changes {VAR} for the rest of "
                                    f"the script (`{row.strip()}`). Set it only as the prefix of a "
                                    f"command that saves no plan")
    return findings, saving


def check(root: Path = ROOT, min_dependencies: int = MIN_DEPENDENCIES,
          min_saving: int = MIN_SAVING_STEPS) -> int:
    visible, why = repo_is_visible(root)
    if not visible:
        print(f"::error::{why}")
        return 2
    if yaml is None:
        print("::error::PyYAML is not installed (pip install pyyaml), so the workflows cannot be "
              "read and this check cannot reach a verdict.")
        return 2
    dependency_findings, seen = check_dependencies(root)
    step_findings, saving = check_workflows(root)
    findings = dependency_findings + step_findings
    for finding in findings:
        print(f"::error::{finding}")
    if findings:
        print(f"✗ {len(findings)} way(s) a plan this repository applies could read a mock output")
        return 1
    if seen < min_dependencies or saving < min_saving:
        print(f"::error::found {seen} dependency block(s) with mocks and {saving} step(s) that save "
              f"a plan, expected at least {min_dependencies} and {min_saving}. The scan did not see "
              f"the tree and refuses to report a pass.")
        return 1
    print(f"✓ none of {seen} dependency block(s) with mocks can hand one to a saved plan, and each "
          f"of {saving} step(s) that save a plan runs with {VAR}=false")
    return 0


# ---------------------------------------------------------------- self-test

def dependency(setting: str | None, mocks: bool = True) -> str:
    body = '  config_path = "../network"\n'
    if mocks:
        body += '  mock_outputs = {\n    vpc_id = "vpc-mock"\n  }\n'
    if setting is not None:
        body += f"  {ATTR} = {setting}\n"
    return f'dependency "network" {{\n{body}}}\n'


SHIPPED = f'{GUARD} ? ["init", "validate", "plan", "destroy"] : ["init", "validate", "destroy"]'
SAVE = 'terragrunt run --non-interactive -- plan -input=false -out="$plan_file"'


def workflow(env: str | None = '"false"', script: tuple[str, ...] = (
        'if [ "$COMPONENT" = "all" ]; then',
        f"  {VAR}=true terragrunt run --all --non-interactive -- plan",
        "  exit 0",
        "fi",
        SAVE)) -> str:
    env_block = f"        env:\n          {VAR}: {env}\n" if env is not None else ""
    run = "".join(f"          {row}\n" for row in script)
    return ("name: Deploy\non: workflow_dispatch\njobs:\n  plan:\n    runs-on: ubuntu-latest\n"
            f"    steps:\n      - name: Plan\n{env_block}        run: |\n{run}")


def tree(hcl: str | bytes | None = None, flow: str | None = None,
         extra: dict[str, str | bytes] | None = None) -> dict[str, str | bytes]:
    files: dict[str, str | bytes] = {
        "live/_envcommon/aws/cluster.hcl": dependency(SHIPPED) if hcl is None else hcl,
        ".github/workflows/deploy.yml": workflow() if flow is None else flow,
    }
    files.update(extra or {})
    return files


def fixture(files: dict[str, str | bytes], git: bool = True) -> tempfile.TemporaryDirectory:
    tmp = tempfile.TemporaryDirectory(prefix="plan-mocks-self-test-")
    root = Path(tmp.name)
    for rel, text in files.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        if isinstance(text, bytes):
            (root / rel).write_bytes(text)
        else:
            (root / rel).write_text(text)
    if git:
        subprocess.run(["git", "init", "-q", str(root)], check=True, timeout=60)
        subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, timeout=60)
    return tmp


def run(fn, *args) -> tuple[int, str]:
    out = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        status = fn(*args)
    return status, out.getvalue()


# (name, files, floors (dependencies, saving steps), status, text the output holds)
RUNS = [
    ("the shipped forms",
     tree(extra={"live/aws/a/us-east-1/development/network/terragrunt.hcl":
                 dependency(f'{GUARD} ? ["validate", "plan"] : ["validate"]'),
                 "live/aws/a/us-east-1/development/dns/terragrunt.hcl": dependency('["validate"]')}),
     (3, 1), 0, "✓ none of 3 dependency block(s)"),
    ("a dependency with no mocks", tree(extra={"live/x.hcl": dependency(None, mocks=False)}),
     (1, 1), 0, "✓ none of 1 dependency block(s)"),
    ("a commented-out dependency",
     tree(extra={"live/y.hcl": "".join(f"# {row}\n" for row in
                                       dependency('["plan"]').splitlines())}),
     (1, 1), 0, "✓ none of 1 dependency block(s)"),
    ("plan in a plain list", tree(dependency('["init", "validate", "plan", "destroy"]')), (1, 1), 1,
     "live/_envcommon/aws/cluster.hcl:6: dependency \"network\": "
     f"{ATTR} admits the mocks to plan in every plan"),
    ("plan kept when the variable is false",
     tree(dependency(f'{GUARD} ? ["plan"] : ["validate", "plan"]')), (1, 1), 1,
     f'admits the mocks to plan even when {VAR} is "false"'),
    ("no list of commands", tree(dependency(None)), (1, 1), 1,
     f"declares mock_outputs and no {ATTR}, which terragrunt reads as every command"),
    ("an empty list", tree(dependency("[]")), (1, 1), 1, "is an empty list"),
    ("an empty list when the variable is false", tree(dependency(f"{GUARD} ? [\"plan\"] : []")),
     (1, 1), 1, "is an empty list"),
    ("apply in a list", tree(dependency(f'{GUARD} ? ["plan", "apply"] : ["validate"]')), (1, 1), 1,
     "names apply"),
    ("another variable", tree(dependency('get_env("OTHER", "true") == "true" ? ["plan"] : []')),
     (1, 1), 1, "write it on one line, as a list that does not name plan"),
    ("a list over two lines", tree(dependency('[\n    "validate",\n  ]')), (1, 1), 1,
     "is `[`: write it on one line"),
    ("a list of something else", tree(dependency("[local.commands]")), (1, 1), 1,
     "names something other than quoted commands"),
    ("a step that saves a plan with no variable", tree(flow=workflow(env=None)), (1, 1), 1,
     f"job 'plan', step 'Plan' saves a plan without {VAR}: \"false\" in its env"),
    ("a step that saves a plan with the variable true", tree(flow=workflow(env='"true"')),
     (1, 1), 1, f"saves a plan without {VAR}"),
    ("the variable set on the command that saves", tree(flow=workflow(script=(f"{VAR}=true {SAVE}",))),
     (1, 1), 1, f"script line 1: sets {VAR} on the command that saves the plan"),
    ("the variable exported", tree(flow=workflow(script=(f"export {VAR}=true", SAVE))), (1, 1), 1,
     f"script line 1: changes {VAR} for the rest of the script (`export {VAR}=true`)"),
    ("the variable assigned before a separator",
     tree(flow=workflow(script=(f"{VAR}=true; echo set", SAVE))), (1, 1), 1,
     f"changes {VAR} for the rest of the script"),
    ("the variable assigned alone", tree(flow=workflow(script=(f"{VAR}=true", SAVE))), (1, 1), 1,
     f"changes {VAR} for the rest of the script"),
    ("the variable unset", tree(flow=workflow(script=(f"unset {VAR}", SAVE))), (1, 1), 1,
     f"changes {VAR} for the rest of the script"),
    ("too few dependency blocks", tree(), (MIN_DEPENDENCIES, 1), 1, "refuses to report a pass"),
    ("no step saves a plan", tree(flow=workflow(script=("terragrunt run -- plan",))), (1, 1), 1,
     "found 1 dependency block(s) with mocks and 0 step(s) that save a plan"),
    ("a workflow that does not parse", tree(flow="jobs: [\n"), (1, 1), 1,
     ".github/workflows/deploy.yml: unreadable"),
    ("an HCL file that is not text", tree(extra={"live/z.hcl": b"\xff\xfe"}), (1, 1), 1,
     "live/z.hcl: unreadable (UnicodeDecodeError)"),
]


def self_test(runs=tuple(RUNS), meta: bool = True) -> int:
    failures: list[str] = []
    for name, files, (min_dependencies, min_saving), want, says in runs:
        with fixture(files) as tmp:
            status, output = run(check, Path(tmp), min_dependencies, min_saving)
        if status != want or says not in output:
            failures.append(f"{name}: exit {status}, wanted {want} with {says!r}\n"
                            + "".join(f"      {line}\n" for line in output.splitlines()[-4:]))
    with fixture(tree(), git=False) as tmp:
        status, output = run(check, Path(tmp), 1, 1)
    if status != 2 or "git" not in output:
        failures.append(f"a tree git does not track: exit {status}, wanted 2 naming git\n      {output}")
    with fixture(tree()) as tmp, mock.patch(f"{__name__}.yaml", None):
        status, output = run(check, Path(tmp), 1, 1)
    if status != 2 or "PyYAML is not installed" not in output:
        failures.append(f"no PyYAML: exit {status}, wanted 2\n      {output}")
    for args in (["--bogus"], ["--self-test", "extra"]):
        status, output = run(cli, args)
        if status != 2:
            failures.append(f"arguments {args}: exit {status}, wanted 2\n      {output.strip()}")
    if meta:
        # A self-test over a case it gets wrong must fail, or it proves nothing.
        wrong = [("plan in a plain list, expected to pass", tree(dependency('["plan"]')), (1, 1), 0, "✓")]
        if run(self_test, wrong, False)[0] == 0:
            failures.append("a self-test whose case expects a plain list naming plan to pass did not fail")
    if failures:
        print("check-plan-mocks.py --self-test FAILED:")
        for failure in failures:
            print("  - " + failure)
        return 1
    print(f"check-plan-mocks.py --self-test: {len(runs)} tree(s), a tree git does not track, a run "
          f"without PyYAML and its arguments behave as the rules say, and a self-test over a wrong "
          f"case fails.")
    return 0


def cli(args: list[str]) -> int:
    if not args:
        return check()
    if args == ["--self-test"]:
        return self_test()
    print("usage: check-plan-mocks.py [--self-test]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(cli(sys.argv[1:]))
