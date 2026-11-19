#!/usr/bin/env python3
"""Every workflow reads AWS account ids and role ARNs as secrets, and masks them first.

WHY THIS EXISTS

The repository is public, and so are its Actions logs. The workflows read AWS
account ids and IAM role ARNs: deploy.yml and destroy.yml DEPLOY_ROLE_ARN and
DEPLOY_ACCOUNT_ID, ci.yml's plan job AWS_ROLE_ARN and TERRAGRUNT_ACCOUNT_ID,
e2e.yml E2E_AWS_ROLE_ARN, drift.yml DRIFT_PLAN_ROLE_ARNS.

Masking cannot rescue a VARIABLE. The runner prints a variable in the env block
of every step that receives it, and an action prints it among its inputs
(`role-to-assume`), before any step of the job can register a mask. Only a
SECRET is masked from the job's first line, and only whole: the account id
inside a role ARN, the state bucket <account_id>-<region>-tfstate in a
terragrunt error, an ARN in an AccessDenied message all print in the clear
unless the job registers them. So the rule has three parts, and an edit can
break any one of them while every other gate stays green and the first symptom
is an account id in a public log:

  - the value is a secret, scoped to the GitHub Environment its job declares;
  - the first step in the job that receives it runs the mask script as its
    first command, so every derived piece is masked before anything prints;
  - it reaches nothing that runs earlier: no workflow- or job-level env, no
    `run:` text, no action input ahead of the mask.

HOW AN ID IS RECOGNISED

By name, and by use. A `secrets.`/`vars.` name whose underscore-separated words
include ROLE_ARN(S) or ACCOUNT_ID(S) is an id (DEPLOY_ROLE_ARN,
TERRAGRUNT_ACCOUNT_ID, DRIFT_PLAN_ROLE_ARNS, a future TERRAGRUNT_ACCOUNT_ID_X).
So is any secret or variable, whatever its name, that some workflow passes as
`role-to-assume`: that input IS a role ARN, and configure-aws-credentials prints
it. A dispatch or workflow_call input with such a name is an id as well, and is
refused outright: an input is typed into a form, kept in the run's event
payload, and printed in the env block of the first step that reads it, so no
step can mask it first.

WHAT IT CHECKS, in every workflow under .github/workflows

  1. No id is read from `vars.`. The one exception is the guard form, which
     compares against '' and passes only `true` or `false`:
     `${{ vars.NAME != '' }}` (and the same for `secrets.`).
  2. No workflow_dispatch or workflow_call input is an id.
  3. An id secret's value appears only in a step's `env:` map or `with:` inputs.
     Not in a workflow- or job-level `env:`: a job-level env is in the process
     environment of every step from the first one, checkout and third-party
     setup actions included, so no step ordering can put the mask ahead of it,
     and the runner prints it in every step's env block (as `***` for a
     secret's whole value, but nothing stops an earlier action from printing a
     piece of it). Not in `run:` text, `if:`, `name:`, `working-directory:`,
     job outputs or a reusable workflow's `with:`/`secrets:`, and no job passes
     `secrets: inherit`, which hands every id to a callee this gate cannot read.
  4. A job that reads an id secret's value declares an `environment:`. A job
     with none may only use the guard form (refuse-inherited-config).
  5. For each id secret, the first step in the job that receives it (in `env:`
     or `with:`) is a `run` step whose first command is the mask script, naming
     every env key in that step that carries the secret:
       bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" [--optional] NAME...
     or, for drift.yml's role map until drift is folded onto the shared script
     (see docs/threat-model.md), `bash "$GITHUB_WORKSPACE/scripts/mask-drift-role-map.sh"`,
     which covers DRIFT_PLAN_ROLE_ARNS. The named script must be tracked.
  6. `role-to-assume` is `${{ secrets.NAME }}` read after rule 5's mask, or
     `${{ steps.ID.outputs.X }}` from a mask step earlier in the same job. Never
     a variable, a matrix value, an input or a literal.
  7. Every aws-actions/configure-aws-credentials step sets
     `mask-aws-account-id: true`.
  8. For every id a workflow reads as a secret, the workflow also compares
     `vars.NAME` against '' (the guard), so a value left behind as a variable
     from before it became a secret fails the run instead of sitting there
     until the next edit prints it.

Rule 8 checks that the comparison exists, not what the shell does with it; the
workflow's step fails on `true`, and its message tells the owner which `gh
variable delete` removes it.

OVERLAP WITH scripts/check-drift-workflow.py (once that lands with the drift
environment change)

That gate owns who may use the `drift` environment (only drift.yml, on
`schedule` and `workflow_dispatch` only) and the shape of drift.yml's guard
job. This one owns where and when an id is read and masked, in every workflow,
drift.yml included. Both currently require drift.yml's first DRIFT_PLAN_ROLE_ARNS
receiver to run mask-drift-role-map.sh; when drift is folded onto
mask-aws-ids.sh that requirement leaves the drift gate and stays here.

EXEMPTION

drift.yml as it is on main before the drift-environment change reads the role
map from a repository VARIABLE and passes role ARNs through the matrix. That
change replaces the file, and it is the change that fixes it, so this gate
exempts drift.yml while its bytes are exactly that file's (pinned by SHA-256).
The exempt findings are still printed, as notices. Any edit to drift.yml, the
drift-environment change included, lapses the exemption and the file is held
to every rule above. A lapsed exemption is reported, not failed, so this change
and the drift change merge in either order; delete the entry when drift is
folded onto the shared script.

USAGE

  check-workflow-id-masking.py              check .github/workflows
  check-workflow-id-masking.py --self-test  mutate copies of the workflows in
                                            ways the rules forbid and require
                                            each to be rejected, citing the file
                                            and the mutated line

Exit 0 = clean. Exit 1 = a violation, or a scan that could not see its inputs.
"""

from __future__ import annotations

import hashlib
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _repo import repo_is_visible

try:
    import yaml
except ImportError:
    print(
        "FAIL: PyYAML is not installed, so this gate cannot read the workflows. "
        "Refusing to report a pass over files it could not parse.",
        file=sys.stderr,
    )
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_REL = ".github/workflows"

ID_NAME = re.compile(r"(?:^|_)(?:ROLE_ARNS?|ACCOUNT_IDS?)(?:_|$)", re.IGNORECASE)
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)
REF = re.compile(r"(?<![\w.])(secrets|vars)\.([A-Za-z_][A-Za-z0-9_]*)")
INPUT_REF = re.compile(r"(?<![\w])(?:github\.event\.)?inputs\.([A-Za-z_][A-Za-z0-9_-]*)")
GUARD = re.compile(r"^\s*(secrets|vars)\.([A-Za-z_][A-Za-z0-9_]*)\s*(?:!=|==)\s*''\s*$")
SECRET_ONLY = re.compile(r"^\s*secrets\.([A-Za-z_][A-Za-z0-9_]*)\s*$")
STEP_OUTPUT_ONLY = re.compile(r"^\s*steps\.([A-Za-z_][A-Za-z0-9_-]*)\.outputs\.[A-Za-z_][A-Za-z0-9_-]*\s*$")
WS = r'"?\$(?:\{GITHUB_WORKSPACE\}|GITHUB_WORKSPACE)'
MASK_AWS = re.compile(rf"^bash\s+{WS}/(scripts/mask-aws-ids\.sh)\"?((?:\s+[A-Za-z_-][A-Za-z0-9_-]*)+)\s*$")
MASK_DRIFT = re.compile(rf"^bash\s+{WS}/(scripts/mask-drift-role-map\.sh)\"?\s*$")
CONFIGURE_AWS = "aws-actions/configure-aws-credentials"

# drift.yml exactly as on main at 52233f8 (the last commit before the
# drift-environment change); see EXEMPTION above.
EXEMPT = {
    ".github/workflows/drift.yml": (
        "b84cd061c0ff4a09d51184ec2f77d5f84cee6620ae3dd04131aac5aeff5f0af1",
        ("reads DRIFT_PLAN_ROLE_ARNS from a repository variable and role ARNs "
         "through the matrix; the drift-environment change replaces the file"),
    ),
}


# --- YAML with line numbers ---------------------------------------------------


class LDict(dict):
    line = 0

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.key_lines: dict = {}
        self.value_lines: dict = {}


class LList(list):
    line = 0


class LineLoader(yaml.SafeLoader):
    pass


def _mapping(loader, node):
    d = LDict()
    d.line = node.start_mark.line + 1
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=True)
        d[key] = loader.construct_object(value_node, deep=True)
        d.key_lines[key] = key_node.start_mark.line + 1
        block = isinstance(value_node, yaml.ScalarNode) and value_node.style in ("|", ">")
        d.value_lines[key] = value_node.start_mark.line + 1 + (1 if block else 0)
    return d


def _sequence(loader, node):
    s = LList(loader.construct_sequence(node, deep=True))
    s.line = node.start_mark.line + 1
    return s


LineLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _mapping)
LineLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_SEQUENCE_TAG, _sequence)


def strings_with_lines(value, line: int):
    """(string, line) for every string inside a parsed value, keys included."""
    if isinstance(value, str):
        yield value, line
    elif isinstance(value, LDict):
        for k, v in value.items():
            kl = value.key_lines.get(k, value.line)
            if isinstance(k, str):
                yield k, kl
            yield from strings_with_lines(v, value.value_lines.get(k, kl))
    elif isinstance(value, list):
        base = getattr(value, "line", line)
        for v in value:
            yield from strings_with_lines(v, getattr(v, "line", base))


def line_in(text: str, start_line: int, needle_index: int) -> int:
    return start_line + text.count("\n", 0, needle_index)


def first_command(run: str) -> tuple[str, int]:
    """The first command of a run block and its offset in lines."""
    for i, raw in enumerate(run.splitlines()):
        line = raw.strip()
        if line and not line.startswith("#"):
            return line, i
    return "", 0


def is_id_name(name: str) -> bool:
    return bool(ID_NAME.search(name))


# --- the check ----------------------------------------------------------------


class Result:
    def __init__(self):
        self.findings: list[tuple[str, int, str]] = []
        self.exempt_notes: list[str] = []
        self.mask_steps = 0
        self.secret_reads = 0
        self.workflows = 0


def check(root: Path) -> Result:
    res = Result()
    wf_dir = root / WORKFLOWS_REL
    paths = sorted(
        p for p in wf_dir.glob("*") if p.suffix in (".yml", ".yaml") and p.is_file()
    ) if wf_dir.is_dir() else []
    res.workflows = len(paths)
    docs = {}
    for p in paths:
        try:
            docs[p] = yaml.load(p.read_text(), Loader=LineLoader)
        except (OSError, yaml.YAMLError) as e:
            res.findings.append((p.relative_to(root).as_posix(), 1, f"could not be parsed: {e}"))
    # Any secret or variable passed as role-to-assume, anywhere, is an id.
    role_names = set()
    for doc in docs.values():
        for job in ((doc or {}).get("jobs") or {}).values():
            for step in (job or {}).get("steps") or [] if isinstance(job, dict) else []:
                w = step.get("with") if isinstance(step, dict) else None
                if isinstance(w, dict) and isinstance(w.get("role-to-assume"), str):
                    for m in EXPR.finditer(w["role-to-assume"]):
                        for kind, name in REF.findall(m.group(1)):
                            role_names.add(name)

    def ident(name: str) -> bool:
        return is_id_name(name) or name in role_names

    for path, doc in docs.items():
        if not isinstance(doc, dict):
            continue
        rel = path.relative_to(root).as_posix()
        out: list[tuple[str, int, str]] = []
        check_workflow(root, rel, doc, ident, out, res)
        exempt = EXEMPT.get(rel)
        if exempt:
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            if digest == exempt[0]:
                res.exempt_notes.append(
                    f"{rel} is exempt while it is byte-identical to the pre-drift-"
                    f"environment file ({exempt[1]}); {len(out)} finding(s) not failing:"
                )
                res.exempt_notes.extend(f"  {r}:{ln}: {msg}" for r, ln, msg in out)
                continue
            res.exempt_notes.append(
                f"{rel} no longer matches its exemption (sha256 {digest[:12]}), so it is "
                "held to every rule. Delete its EXEMPT entry."
            )
        res.findings.extend(out)
    return res


def check_workflow(root, rel, doc, ident, out, res) -> None:
    def bad(line: int, msg: str) -> None:
        out.append((rel, line, msg))

    jobs = doc.get("jobs") or {}
    guarded_vars: set[str] = set()     # vars.NAME compared against ''
    secret_reads: dict[str, int] = {}  # id secret name -> first line read

    def scan(value, line, where: str, allow_secret: bool):
        """Classify every expression in `value`. Returns {id secret name} read."""
        found = set()
        for text, ln in strings_with_lines(value, line):
            spans = [(m.group(1), m.start()) for m in EXPR.finditer(text)]
            if where == "if" and "${{" not in text:
                spans = [(text, 0)]
            for expr, idx in spans:
                at = line_in(text, ln, idx)
                g = GUARD.match(expr)
                if g:
                    if g.group(1) == "vars":
                        guarded_vars.add(g.group(2))
                    continue
                for kind, name in REF.findall(expr):
                    if not ident(name):
                        continue
                    if kind == "vars":
                        bad(at, f"reads {name}, an AWS account id or role ARN, from "
                                "`vars.` in its " + where + ". A variable is never masked: "
                                "the runner prints it in the env block and the inputs of every "
                                "step that receives it, before any step can mask it. Make it a "
                                "secret on the GitHub Environment the job declares (see "
                                "docs/operations.md); only the guard form "
                                f"`${{{{ vars.{name} != '' }}}}` may name the variable.")
                        continue
                    res.secret_reads += 1
                    secret_reads.setdefault(name, at)
                    if not allow_secret:
                        bad(at, f"passes the id secret {name} through its {where}. It may "
                                "reach a step only through that step's `env:` map or `with:` "
                                "inputs, after the job's mask step: anywhere else it reaches "
                                "steps that run before the mask, or is expanded into text "
                                "where its pieces are printed unmasked.")
                    found.add(name)
                for m in INPUT_REF.finditer(expr):
                    if ident(m.group(1)):
                        bad(at, f"reads the input {m.group(1)}, an AWS account id or role "
                                "ARN. An input cannot be masked before it is printed; take it "
                                "from a secret on the job's environment instead.")
        return found

    # Workflow-level: triggers' inputs and env.
    on = doc.get("on", doc.get(True))
    if isinstance(on, dict):
        for trig in ("workflow_dispatch", "workflow_call"):
            spec = on.get(trig)
            inputs = spec.get("inputs") if isinstance(spec, dict) else None
            if isinstance(inputs, LDict):
                for name in inputs:
                    if isinstance(name, str) and is_id_name(name):
                        bad(inputs.key_lines.get(name, inputs.line),
                            f"declares the {trig} input '{name}', an AWS account id or "
                            "role ARN. An input is typed into the dispatch form, kept in the "
                            "run's event payload and printed in the env block of the first "
                            "step that reads it, so no step can mask it first. Take it from "
                            "a secret on the job's environment (or derive it from one).")
    for key in doc:
        if key in ("on", True, "jobs"):
            continue
        scan(doc[key], doc.key_lines.get(key, 1), f"workflow-level `{key}`", False)

    for job_id, job in jobs.items():
        if not isinstance(job, LDict):
            continue
        job_line = jobs.key_lines.get(job_id, job.line)
        reads_value: dict[str, int] = {}  # id secret name -> first line in this job
        for key in job:
            if key == "steps":
                continue
            kl = job.key_lines.get(key, job.line)
            if key == "secrets" and job[key] == "inherit":
                bad(kl, f"job '{job_id}' passes `secrets: inherit`, which hands every "
                        "secret, account ids and role ARNs included, to a reusable workflow "
                        "this gate cannot read. Pass the secrets it needs by name.")
                continue
            for name in scan(job[key], job.value_lines.get(key, kl), f"job-level `{key}`", False):
                reads_value.setdefault(name, kl)

        masked: set[str] = set()
        mask_step_ids: set[str] = set()
        for step in job.get("steps") or []:
            if not isinstance(step, LDict):
                continue
            receives: dict[str, list[tuple[str, int]]] = {}  # name -> [(where, line)]
            for key in step:
                kl = step.key_lines.get(key, step.line)
                vl = step.value_lines.get(key, kl)
                if key in ("env", "with") and isinstance(step[key], LDict):
                    block = step[key]
                    for k, v in block.items():
                        kline = block.key_lines.get(k, block.line)
                        for name in scan(v, block.value_lines.get(k, kline), f"`{key}`", True):
                            receives.setdefault(name, []).append((f"{key}.{k}", kline))
                else:
                    scan(step[key], vl, f"step `{key}`", False)
            for name, places in receives.items():
                reads_value.setdefault(name, places[0][1])

            run = step.get("run") if isinstance(step.get("run"), str) else None
            cmd, offset = first_command(run or "")
            cmd_line = step.value_lines.get("run", step.line) + offset
            covers: set[str] | None = None
            script = None
            m = MASK_AWS.match(cmd)
            if m:
                script = m.group(1)
                covers = {a for a in m.group(2).split() if not a.startswith("--")}
            else:
                m = MASK_DRIFT.match(cmd)
                if m:
                    script = m.group(1)
                    covers = {"DRIFT_PLAN_ROLE_ARNS"}
            if script:
                res.mask_steps += 1
                if not (root / script).is_file():
                    bad(cmd_line, f"runs {script}, which is not in the tree, so nothing "
                                  "is masked.")
                elif isinstance(step.get("id"), str):
                    mask_step_ids.add(step["id"])

            for name, places in receives.items():
                if name in masked:
                    continue
                masked.add(name)
                env_keys = [w.split(".", 1)[1] for w, _ in places if w.startswith("env.")]
                with_places = [(w, ln) for w, ln in places if w.startswith("with.")]
                step_name = step.get("name", step.get("uses", "?"))
                if with_places or not run:
                    where, ln = (with_places or places)[0]
                    bad(ln, f"job '{job_id}', step '{step_name}' is the first to receive "
                            f"{name} ({where}), and it is not a mask step. The first step "
                            "that receives an id secret must be a `run` step whose first "
                            'command is `bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" '
                            f'{name}`; an action prints its inputs before it runs.')
                elif covers is None:
                    bad(cmd_line, f"job '{job_id}', step '{step_name}' is the first to "
                                  f"receive {name}, and its first command is {cmd[:70]!r}, "
                                  'not `bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" '
                                  f'{" ".join(env_keys)}`. Masks take effect from the line '
                                  "after `::add-mask::`, so anything before it can print a "
                                  "piece of the value.")
                else:
                    missing = [k for k in env_keys if k not in covers]
                    if missing:
                        bad(cmd_line, f"job '{job_id}', step '{step_name}': the mask "
                                      f"command does not name {', '.join(missing)}, which "
                                      f"carries {name} into this step, so its pieces are "
                                      "never masked.")

            uses = step.get("uses")
            w = step.get("with")
            if isinstance(w, LDict) and "role-to-assume" in w:
                v = w["role-to-assume"]
                ln = w.key_lines.get("role-to-assume", w.line)
                inner = EXPR.fullmatch(v.strip()) if isinstance(v, str) else None
                ok = False
                if inner:
                    so = SECRET_ONLY.match(inner.group(1))
                    po = STEP_OUTPUT_ONLY.match(inner.group(1))
                    ok = bool(so) or bool(po and po.group(1) in mask_step_ids)
                if not ok:
                    bad(ln, f"job '{job_id}': role-to-assume is {str(v)[:60]!r}. It must be "
                            "`${{ secrets.NAME }}`, read after the job's mask step, or "
                            "`${{ steps.ID.outputs.X }}` from that mask step. The action "
                            "prints this input, so a variable, matrix value, input or literal "
                            "here publishes the role ARN and its account id.")
            if isinstance(uses, str) and uses.split("@")[0] == CONFIGURE_AWS:
                mask = w.get("mask-aws-account-id") if isinstance(w, dict) else None
                if str(mask).lower() != "true":
                    bad(step.key_lines.get("uses", step.line),
                        f"job '{job_id}': {CONFIGURE_AWS} without `mask-aws-account-id: "
                        "true`. The job's mask step registers the id already; stating it "
                        "keeps the action's own handling of the account id it reads back "
                        "from being the one place it is not.")

        if reads_value and not job.get("environment"):
            name, ln = min(reads_value.items(), key=lambda kv: kv[1])
            bad(ln, f"job '{job_id}' (line {job_line}) reads the value of {name} but "
                    "declares no environment. Each id is a secret on the GitHub "
                          "Environment its job declares; a job with no environment sees only "
                          "repository and organization secrets, and may only compare them "
                          "against '' (the guard form).")

    for name, ln in sorted(secret_reads.items(), key=lambda kv: kv[1]):
        if name not in guarded_vars:
            bad(ln, f"reads the id secret {name}, and nothing in this workflow compares "
                    f"`vars.{name}` against ''. A value left behind as a variable from before "
                    "it became a secret must fail the run (it is never masked, and the next "
                    f"edit that reads it prints it): add `${{{{ vars.{name} != '' }}}}` to "
                    "the env of the first step that receives the secret, and fail on true.")


def report(res: Result) -> int:
    for note in res.exempt_notes:
        print(f"::notice::{note}" if not note.startswith("  ") else note)
    if res.findings:
        for rel, line, msg in res.findings:
            print(f"::error file={rel},line={line}::{rel}:{line}: {msg}")
        print(f"\n{len(res.findings)} finding(s). See the docstring of "
              "scripts/check-workflow-id-masking.py and docs/operations.md.")
        return 1
    print(f"OK: {res.workflows} workflow(s) read; {res.secret_reads} id secret read(s), "
          f"each masked first by one of {res.mask_steps} mask step(s), none from vars.")
    return 0


def main_check() -> int:
    ok, why = repo_is_visible(ROOT)
    if not ok:
        print(f"::error::{why} Refusing to report a pass.")
        return 1
    res = check(ROOT)
    if res.workflows < 4 or res.mask_steps < 4:
        print(f"::error::read {res.workflows} workflow(s) and {res.mask_steps} mask step(s) "
              "under .github/workflows (expected at least 4 of each). This gate did not "
              "see what it checks and refuses to report a pass.")
        return 1
    return report(res)


# --- self-test ----------------------------------------------------------------

# (name, file, old, new, expected line: None = a line inside `new`, or a regex
# naming the line in the mutated file the finding must cite)
MUTATIONS = [
    ("role-to-assume from a variable", "deploy.yml",
     "role-to-assume: ${{ secrets.DEPLOY_ROLE_ARN }}",
     "role-to-assume: ${{ vars.DEPLOY_ROLE_ARN }}", None),
    ("a variable in a later step's env", "deploy.yml",
     "          DEPLOY_ACCOUNT_ID: ${{ secrets.DEPLOY_ACCOUNT_ID }}\n          TARGET_ENV: ${{ inputs.environment }}\n        run: |\n          if ! caller_account",
     "          DEPLOY_ACCOUNT_ID: ${{ vars.DEPLOY_ACCOUNT_ID }}\n          TARGET_ENV: ${{ inputs.environment }}\n        run: |\n          if ! caller_account",
     None),
    ("a step receives the secret before the mask step", "deploy.yml",
     "      - name: Require DEPLOY_ROLE_ARN, DEPLOY_ACCOUNT_ID and a matching leaf\n",
     ("      - name: Early\n        env:\n          EARLY: ${{ secrets.DEPLOY_ACCOUNT_ID }}\n        run: echo early\n"
      "      - name: Require DEPLOY_ROLE_ARN, DEPLOY_ACCOUNT_ID and a matching leaf\n"), None),
    ("the mask is not the first command", "destroy.yml",
     '        run: |\n          bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" --optional DEPLOY_ROLE_ARN DEPLOY_ACCOUNT_ID\n',
     '        run: |\n          echo "starting"\n          bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" --optional DEPLOY_ROLE_ARN DEPLOY_ACCOUNT_ID\n',
     None),
    ("the guard job reads the secret's value", "destroy.yml",
     "INHERITED_ROLE_ARN_SECRET: ${{ secrets.DEPLOY_ROLE_ARN != '' }}",
     "INHERITED_ROLE_ARN_SECRET: ${{ secrets.DEPLOY_ROLE_ARN }}", None),
    ("the mask command omits a secret the step receives", "ci.yml",
     "--optional AWS_ROLE_ARN TERRAGRUNT_ACCOUNT_ID\n",
     "--optional AWS_ROLE_ARN\n", None),
    ("the secret expanded into run text", "ci.yml",
     "        run: terragrunt plan -lock=false -no-color\n",
     "        run: terragrunt plan -lock=false -no-color -var account=${{ secrets.TERRAGRUNT_ACCOUNT_ID }}\n",
     None),
    ("role-to-assume from the matrix", "ci.yml",
     "role-to-assume: ${{ secrets.AWS_ROLE_ARN }}",
     "role-to-assume: ${{ matrix.role_arn }}", None),
    ("the secret in a workflow-level env", "ci.yml",
     "permissions:\n  contents: read\n\njobs:\n",
     "permissions:\n  contents: read\n\nenv:\n  TERRAGRUNT_ACCOUNT_ID: ${{ secrets.TERRAGRUNT_ACCOUNT_ID }}\n\njobs:\n",
     None),
    ("the secret in a job-level env", "e2e.yml",
     "    environment: e2e\n",
     "    environment: e2e\n    env:\n      E2E_AWS_ROLE_ARN: ${{ secrets.E2E_AWS_ROLE_ARN }}\n", None),
    ("an account id as a dispatch input", "e2e.yml",
     "      region:\n        description: \"Region\"\n",
     ("      account_id:\n        description: \"Target AWS account ID\"\n"
      "      region:\n        description: \"Region\"\n"), None),
    ("the leftover-variable guard removed", "e2e.yml",
     "ROLE_ARN_VARIABLE: ${{ vars.E2E_AWS_ROLE_ARN != '' }}",
     "ROLE_ARN_VARIABLE: \"false\"",
     r"^\s+E2E_AWS_ROLE_ARN: \$\{\{ secrets\.E2E_AWS_ROLE_ARN \}\}"),
    ("an action is the first step to receive the secret", "e2e.yml",
     "          E2E_AWS_ROLE_ARN: ${{ secrets.E2E_AWS_ROLE_ARN }}\n          ROLE_ARN_VARIABLE",
     "          E2E_AWS_ROLE_ARN: ${{ steps.none.outputs.none }}\n          ROLE_ARN_VARIABLE",
     r"^\s+role-to-assume: \$\{\{ secrets\.E2E_AWS_ROLE_ARN \}\}"),
    ("configure-aws-credentials without mask-aws-account-id", "deploy.yml",
     "          mask-aws-account-id: true\n", "",
     r"^\s+uses: aws-actions/configure-aws-credentials@"),
    ("secrets: inherit", "e2e.yml",
     "    environment: e2e\n", "    environment: e2e\n    secrets: inherit\n", None),
]


def self_test() -> int:
    failures = 0
    ran = 0
    with tempfile.TemporaryDirectory(prefix="id-masking-") as tmp:
        base = Path(tmp) / "base"
        (base / WORKFLOWS_REL).mkdir(parents=True)
        for p in (ROOT / WORKFLOWS_REL).glob("*.y*ml"):
            shutil.copy(p, base / WORKFLOWS_REL / p.name)
        (base / "scripts").mkdir()
        for s in ("mask-aws-ids.sh", "mask-drift-role-map.sh"):
            if (ROOT / "scripts" / s).is_file():
                shutil.copy(ROOT / "scripts" / s, base / "scripts" / s)

        clean = check(base)
        if clean.findings:
            print("FAIL [unmutated]: the gate rejects the workflows as they are:", file=sys.stderr)
            for rel, ln, msg in clean.findings:
                print(f"  {rel}:{ln}: {msg[:120]}", file=sys.stderr)
            return 1

        mutations = list(MUTATIONS)
        # The exemption is pinned to bytes: one appended line lapses it.
        drift = base / WORKFLOWS_REL / "drift.yml"
        rel_drift = f"{WORKFLOWS_REL}/drift.yml"
        if drift.is_file() and rel_drift in EXEMPT and \
                hashlib.sha256(drift.read_bytes()).hexdigest() == EXEMPT[rel_drift][0]:
            mutations.append(("an edit lapses drift.yml's exemption", "drift.yml",
                              "jobs:\n", "jobs:\n", r"vars\.DRIFT_PLAN_ROLE_ARNS"))
        for name, fname, old, new, expect in mutations:
            ran += 1
            target = base / WORKFLOWS_REL / fname
            text = target.read_text()
            if fname == "drift.yml" and old == new:
                mutated = text + "# an unrelated edit\n"
            else:
                if text.count(old) != 1:
                    print(f"FAIL [{name}]: anchor found {text.count(old)} time(s) in {fname}",
                          file=sys.stderr)
                    failures += 1
                    continue
                mutated = text.replace(old, new)
            target.write_text(mutated)
            try:
                res = check(base)
            finally:
                target.write_text(text)
            rel = f"{WORKFLOWS_REL}/{fname}"
            lines = mutated.splitlines()
            if expect is None:
                start = mutated.index(new) if new else 0
                first = mutated.count("\n", 0, start) + 1
                wanted = set(range(first, first + max(1, new.count("\n") + (0 if new.endswith("\n") else 1))))
            else:
                wanted = {i + 1 for i, ln in enumerate(lines) if re.search(expect, ln)}
            cited = {ln for r, ln, _ in res.findings if r == rel}
            if not res.findings:
                print(f"FAIL [{name}]: not rejected", file=sys.stderr)
                failures += 1
            elif not (cited & wanted):
                print(f"FAIL [{name}]: rejected, but cited {sorted(cited) or 'no line'} in "
                      f"{rel}, not the mutated line(s) {sorted(wanted)}", file=sys.stderr)
                failures += 1
            else:
                hit = next(f for f in res.findings if f[0] == rel and f[1] in wanted)
                print(f"ok [{name}]: {hit[0]}:{hit[1]}: {hit[2][:90]}")
    if failures:
        print(f"check-workflow-id-masking self-test FAILED: {failures} of {ran} mutation(s)",
              file=sys.stderr)
        return 1
    if ran < len(MUTATIONS):
        print("self-test ran fewer mutations than it lists; refusing to report a pass",
              file=sys.stderr)
        return 1
    print(f"check-workflow-id-masking self-test passed ({ran} mutations rejected at the "
          "mutated line, unmutated workflows accepted).")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    if sys.argv[1:]:
        print("usage: check-workflow-id-masking.py [--self-test]", file=sys.stderr)
        sys.exit(2)
    sys.exit(main_check())
