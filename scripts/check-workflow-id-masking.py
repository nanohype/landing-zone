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
terragrunt error, an ARN in an AccessDenied message, a value an expression
computes from the secret (`fromJSON(secrets.MAP).dev`) all print in the clear
unless the job registers them. So the rule has four parts, and an edit can break
any one of them while every other gate stays green and the first symptom is an
account id in a public log:

  - the value is a secret, scoped to the GitHub Environment its job declares,
    and a job without that environment refuses the same name at repository or
    organization level;
  - the first step in the job that receives it runs the mask script as its
    first command, unconditionally, so every derived piece is masked before
    anything prints;
  - it reaches a step only whole, as `${{ secrets.NAME }}`, and pieces of it
    are cut out in shell after the mask and handed on as step outputs;
  - it reaches nothing that runs earlier: no workflow- or job-level env, no
    `run:` text, no action input ahead of the mask.

HOW AN EXPRESSION IS READ

Each `${{ }}` (and each bare `if:`) is tokenised, not pattern-matched, because
the expression language has more than one spelling for a read: context names
are case-insensitive (`Secrets.X`, `VARS.X`), a property can be indexed
(`secrets['X']`, `github.event.inputs['x']`), and a whole context can be read
at once (`toJSON(secrets)`). A literal index resolves to its name. A read of a
whole `secrets`, `vars` or `inputs` context, or one through a computed index
(`vars[format('{0}_ACCOUNT_ID', matrix.env)]`) or a `*` filter, is a finding
wherever it appears: the gate cannot tell what it names, so it cannot prove it
names no id. An expression the tokeniser cannot read is a finding when it
mentions one of those contexts. Secret, variable and input names are compared
case-insensitively, as GitHub resolves them.

HOW AN ID IS RECOGNISED

By name, by use, and by where it goes.

  - By name. A name whose `_`- or `-`-separated words include ROLE_ARN(S),
    ARN(S), ACCOUNT_ID(S), ACCOUNT_NUMBER(S), AWS_ACCOUNT(S), STATE_BUCKET(S)
    or TFSTATE is an id (DEPLOY_ROLE_ARN, TERRAGRUNT_ACCOUNT_ID,
    DRIFT_PLAN_ROLE_ARNS, TF_STATE_BUCKET, aws_account). THIS IS A NAMING RULE
    for the repository, not only a heuristic: a secret, variable or input that
    carries an account id, a role ARN or the state bucket (which is named after
    the account) is named so that it matches. CLAUDE.md states it.
  - By use. Any secret or variable, whatever its name, that some workflow
    passes as `role-to-assume`, puts whole into an env or `with:` key whose own
    name is an id (TERRAGRUNT_ACCOUNT_ID, E2E_ACCOUNT_ID, ACCOUNT_ID), or hands
    a mask step to mask, is an id everywhere.
  - By where it goes (the sinks). Such a key, a mask step's masked env keys and
    `role-to-assume` accept only a secret read whole, an output of a mask step
    earlier in the job, the guard form, or a literal (which rule 9 reads).
    Never a variable, an input, a matrix value or another job's output,
    whatever its name.
  - In a job that can hold AWS credentials (it uses configure-aws-credentials
    or may mint an OIDC token), no variable is read at all except in the guard
    form or by name from VARS_ALLOWED, which is empty: such a job has no reason
    to read configuration that is not a secret, and a variable named outside
    the rule is still printed.

WHAT IT CHECKS, in every workflow under .github/workflows

  1. No id is read from `vars.`, and an AWS job reads no variable (above). The
     one exception is the guard form, which compares against '' and passes only
     `true` or `false`: `${{ vars.NAME != '' }}` (and the same for `secrets.`).
     No `secrets`, `vars` or `inputs` context is read whole or through a
     computed index.
  2. No workflow_dispatch or workflow_call input is an id, and no expression
     reads an input with an id's name.
  3. An id secret's value appears only as the ENTIRE value of a step's `env:`
     entry or `with:` input: `${{ secrets.NAME }}` and nothing else. Anything
     that computes from it (`fromJSON(...)`, `toJSON(...)`, `format(...)`, an
     index, a concatenation) yields a value the runner does not know to mask,
     printed in the env block of that step before its first command can mask
     it. Not in a workflow- or job-level `env:` either: a job-level env is in
     the process environment of every step from the first one, checkout and
     third-party setup actions included, so no step ordering can put the mask
     ahead of it. Not in `run:` text, `if:`, `name:`, `working-directory:`,
     job outputs or a reusable workflow's `with:`/`secrets:`, and no job passes
     `secrets: inherit`, which hands every id to a callee this gate cannot read.
  4. A job that reads an id secret's value declares an `environment:`, and
     needs (directly or through other jobs) a job with NO environment that
     compares `secrets.NAME` against '' (refuse-inherited-config). The secrets
     context falls back from the environment to the repository and the
     organization, so without that job a value stored at repository level (a
     migration that left off --env) is read, every workflow in the repository
     can read it, and the run stays green. A job with no environment may only
     use the guard form.
  5. For each id secret, the first step in the job that receives it (in `env:`
     or `with:`) is a `run` step whose first command is the mask script, in the
     script's own grammar, naming every env key in that step that carries the
     secret:
       bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" [--optional] NAME...
     with --optional only first and each NAME an environment variable name
     (drift.yml's role map included: `mask-aws-ids.sh DRIFT_PLAN_ROLE_ARNS`;
     there is no second mask script). The named script must be tracked, and
     every key it names must be in the step's env holding `${{ secrets.X }}`.
     A mask step must run whenever the job does and stop it on failure: no
     `if:`, no `continue-on-error`, and a shell (the step's, else the job's
     `defaults.run.shell`, else the workflow's) that is unset or `bash`. A
     later step that receives the secret may not run after a failure
     (`always()`, `failure()`, `cancelled()` in its `if:`): a step before the
     mask failing skips the mask, and such a step would then run unmasked.
  6. `role-to-assume` is `${{ secrets.NAME }}` read after rule 5's mask, or
     `${{ steps.ID.outputs.X }}` from a mask step earlier in the same job. Never
     a variable, a matrix value, an input or a literal.
  7. Every aws-actions/configure-aws-credentials step (owner and repository
     compared case-insensitively, as GitHub resolves them) sets
     `mask-aws-account-id: true`.
  8. For every id a workflow reads as a secret, the workflow also compares
     `vars.NAME` against '' (the guard), so a value left behind as a variable
     from before it became a secret fails the run instead of sitting there
     until the next edit prints it.
  9. No string in a workflow other than a `uses:` reference carries a literal
     twelve-digit account id or an ARN with one, except the tree's synthetic
     placeholders (one digit repeated, or 123456789012).

Rules 4 and 8 check that the comparison exists, not what the shell does with
it; the workflow's step fails on `true`, and its message names the `gh` command
that removes the value.

OVERLAP WITH scripts/check-drift-workflow.py

That gate owns who may use the `drift` environment (only drift.yml, on
`schedule` and `workflow_dispatch` only) and the shape of drift.yml's guard
job. This one owns where and when an id is read and masked, in every workflow,
drift.yml included: the mask-first rule for DRIFT_PLAN_ROLE_ARNS lives here
alone. No workflow is exempt.

USAGE

  check-workflow-id-masking.py              check .github/workflows
  check-workflow-id-masking.py --self-test  mutate copies of the workflows in
                                            ways the rules forbid and require
                                            each to be rejected, citing the file
                                            and the mutated line

Exit 0 = clean. Exit 1 = a violation, or a scan that could not see its inputs.
"""

from __future__ import annotations

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

ID_NAME = re.compile(
    r"(?:^|[_-])(?:ROLE[_-]ARNS?|ARNS?|ACCOUNT[_-]IDS?|ACCOUNT[_-]NUMBERS?|AWS[_-]ACCOUNTS?"
    r"|STATE[_-]BUCKETS?|TFSTATE)(?:[_-]|$)",
    re.IGNORECASE,
)
# with: keys that look like an id by name and hold a switch, not an id.
NOT_A_SINK = {"mask-aws-account-id"}
EXPR = re.compile(r"\$\{\{(.*?)\}\}", re.DOTALL)
WS = r'"?\$(?:\{GITHUB_WORKSPACE\}|GITHUB_WORKSPACE)'
# The script's own grammar: --optional only first, then environment variable names.
MASK_AWS = re.compile(
    rf"^bash\s+{WS}/(scripts/mask-aws-ids\.sh)\"?(\s+--optional)?((?:\s+[A-Za-z_][A-Za-z0-9_]*)+)\s*$")
CONFIGURE_AWS = "aws-actions/configure-aws-credentials"
AFTER_FAILURE = re.compile(r"\b(?:always|failure|cancelled)\s*\(", re.IGNORECASE)
ARN_LITERAL = re.compile(r"arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:([0-9]{12})(?![0-9])")
ID_LITERAL = re.compile(r"(?<![0-9A-Za-z])([0-9]{12})(?![0-9A-Za-z])")
# Variable names a job holding AWS credentials may read other than in the guard
# form. Empty: add a name here only with the reason it can never carry an id.
VARS_ALLOWED: set[str] = set()
# The ids the workflows read today. The floor requires the scan to have seen
# each one read as a secret, so a tokeniser that stops recognising reads cannot
# report a clean tree.
KNOWN_ID_READS = {"DEPLOY_ROLE_ARN", "DEPLOY_ACCOUNT_ID", "AWS_ROLE_ARN",
                      "TERRAGRUNT_ACCOUNT_ID", "E2E_AWS_ROLE_ARN", "DRIFT_PLAN_ROLE_ARNS"}
# The workflows and mask steps there are today (deploy, destroy, ci's plan job,
# e2e, and drift's two jobs that read the role map). Fewer means the scan
# stopped seeing them, or a workflow stopped masking; lower these only with the
# change that removes one.
MIN_WORKFLOWS = 5
MIN_MASK_STEPS = 6


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


def strings_with_lines(value, line: int, skip_keys: tuple = ()):
    """(string, line) for every string inside a parsed value, keys included."""
    if isinstance(value, str):
        yield value, line
    elif isinstance(value, LDict):
        for k, v in value.items():
            kl = value.key_lines.get(k, value.line)
            if isinstance(k, str):
                yield k, kl
            if k in skip_keys:
                continue
            yield from strings_with_lines(v, value.value_lines.get(k, kl), skip_keys)
    elif isinstance(value, list):
        base = getattr(value, "line", line)
        for v in value:
            yield from strings_with_lines(v, getattr(v, "line", base), skip_keys)


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


def is_sink_key(key) -> bool:
    return isinstance(key, str) and key.lower() not in NOT_A_SINK and is_id_name(key)


def placeholder(digits: str) -> bool:
    return len(set(digits)) == 1 or digits == "123456789012"


# --- expressions --------------------------------------------------------------

TOKEN = re.compile(r"""
    (?P<ws>\s+)
  | (?P<str>'(?:[^']|'')*')
  | (?P<num>-?(?:0x[0-9A-Fa-f]+|[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?))
  | (?P<ident>[A-Za-z_][A-Za-z0-9_-]*)
  | (?P<op>==|!=|<=|>=|&&|\|\||[!<>().,\[\]*])
""", re.VERBOSE)
CONTEXT_WORDS = re.compile(r"(?i)\b(?:secrets|vars|inputs)\b")


def tokenize(expr: str):
    toks, i = [], 0
    while i < len(expr):
        m = TOKEN.match(expr, i)
        if not m:
            return None
        i = m.end()
        if m.lastgroup != "ws":
            toks.append((m.lastgroup, m.group()))
    return toks


class Ref:
    """A context read: its name (lower-cased), the accessor chain, and its span."""

    def __init__(self, ctx: str, path: list, start: int, end: int):
        self.ctx, self.path, self.start, self.end = ctx, path, start, end


def refs(toks) -> list[Ref]:
    out, n = [], len(toks)
    for i, (kind, value) in enumerate(toks):
        if kind != "ident" or (i and toks[i - 1][1] == ".") or (i + 1 < n and toks[i + 1][1] == "("):
            continue
        if value.lower() in ("true", "false", "null"):
            continue
        path, j = [], i + 1
        while j < n:
            if toks[j][1] == "." and j + 1 < n:
                k, v = toks[j + 1]
                if k == "ident":
                    path.append(("name", v))
                elif v == "*":
                    path.append(("star", None))
                else:
                    break
                j += 2
            elif toks[j][1] == "[":
                depth, m = 1, j + 1
                while m < n and depth:
                    depth += {"[": 1, "]": -1}.get(toks[m][1], 0)
                    m += 1
                inner = toks[j + 1:m - 1]
                if len(inner) == 1 and inner[0][0] == "str":
                    path.append(("name", inner[0][1][1:-1].replace("''", "'")))
                else:
                    path.append(("dynamic", None))
                j = m
            else:
                break
        out.append(Ref(value.lower(), path, i, j))
    return out


def resolve(r: Ref):
    """(context, name, problem) for a secrets/vars/inputs read, else None.

    context is 'secrets', 'vars' or 'inputs'; problem is None, 'whole' (the
    context itself) or 'computed' (a dynamic index or a filter)."""
    path = r.path
    if r.ctx == "github":
        if len(path) >= 2 and path[0][0] == "name" and path[0][1].lower() == "event" \
                and path[1][0] == "name" and path[1][1].lower() == "inputs":
            ctx, path = "inputs", path[2:]
        else:
            return None
    elif r.ctx in ("secrets", "vars", "inputs"):
        ctx = r.ctx
    else:
        return None
    if not path:
        return ctx, None, "whole"
    if path[0][0] != "name":
        return ctx, None, "computed"
    return ctx, path[0][1], None


def sole(toks, rs) -> Ref | None:
    """The one read that is the whole expression, with a single accessor."""
    if len(rs) == 1 and rs[0].start == 0 and rs[0].end == len(toks):
        return rs[0]
    return None


def guard_ref(toks, rs) -> Ref | None:
    """The read in `ctx.NAME != ''` (or ==, either order), else None."""
    if len(rs) != 1:
        return None
    r = rs[0]
    before, after = toks[:r.start], toks[r.end:]
    cmp = ("==", "!=")
    if not before and len(after) == 2 and after[0][1] in cmp and after[1] == ("str", "''"):
        return r
    if not after and len(before) == 2 and before[0] == ("str", "''") and before[1][1] in cmp:
        return r
    return None


def expressions(text: str, is_if: bool):
    """(expression, offset) for each `${{ }}` in text; a bare `if:` is one."""
    spans = [(m.group(1), m.start()) for m in EXPR.finditer(text)]
    if is_if and "${{" not in text:
        spans = [(text, 0)]
    return spans


def exact_expr(text) -> str | None:
    """The expression when the whole string is one `${{ }}`, else None."""
    if not isinstance(text, str):
        return None
    m = EXPR.fullmatch(text.strip())
    return m.group(1) if m else None


def whole_read_name(text) -> str | None:
    """NAME when the whole string is `${{ secrets.NAME }}` (any spelling)."""
    expr = exact_expr(text)
    toks = tokenize(expr) if expr is not None else None
    if not toks:
        return None
    r = sole(toks, refs(toks))
    got = resolve(r) if r else None
    if got and got[0] == "secrets" and got[2] is None and len(r.path) == 1:
        return got[1]
    return None


def named_reads(text) -> set[str]:
    """Upper-cased secret and variable names a string reads by name."""
    names = set()
    if not isinstance(text, str):
        return names
    for expr, _ in expressions(text, False):
        toks = tokenize(expr) or []
        for r in refs(toks):
            got = resolve(r)
            if got and got[0] in ("secrets", "vars") and got[1]:
                names.add(got[1].upper())
    return names


def step_output_whole(text) -> str | None:
    """ID when the whole string is `${{ steps.ID.outputs.X }}`."""
    expr = exact_expr(text)
    toks = tokenize(expr) if expr is not None else None
    if not toks:
        return None
    r = sole(toks, refs(toks))
    if r and r.ctx == "steps" and len(r.path) == 3 and all(k == "name" for k, _ in r.path) \
            and r.path[1][1].lower() == "outputs":
        return r.path[0][1].lower()
    return None


def is_guard(text) -> bool:
    expr = exact_expr(text)
    toks = tokenize(expr) if expr is not None else None
    if not toks:
        return False
    r = guard_ref(toks, refs(toks))
    got = resolve(r) if r else None
    return bool(got and got[0] in ("secrets", "vars") and got[2] is None and len(r.path) == 1)


def mask_command(step) -> tuple[str | None, set[str] | None, int]:
    """(script, names it masks, line offset) when the step's first command masks."""
    run = step.get("run") if isinstance(step, dict) and isinstance(step.get("run"), str) else ""
    cmd, offset = first_command(run)
    m = MASK_AWS.match(cmd)
    if m:
        return m.group(1), set(m.group(3).split()), offset
    return None, None, offset


def uses_configure_aws(step) -> bool:
    uses = step.get("uses") if isinstance(step, dict) else None
    return isinstance(uses, str) and uses.split("@")[0].strip().lower() == CONFIGURE_AWS


def job_steps(job):
    steps = job.get("steps") if isinstance(job, dict) else None
    return [s for s in steps if isinstance(s, dict)] if isinstance(steps, list) else []


def shell_of(node) -> str | None:
    d = node.get("defaults") if isinstance(node, dict) else None
    r = d.get("run") if isinstance(d, dict) else None
    s = r.get("shell") if isinstance(r, dict) else None
    return s if isinstance(s, str) else None


def holds_aws(doc, job) -> bool:
    if any(uses_configure_aws(s) for s in job_steps(job)):
        return True
    perms = job.get("permissions", doc.get("permissions"))
    if perms == "write-all":
        return True
    return isinstance(perms, dict) and str(perms.get("id-token", "")).lower() == "write"


def collect_ids_by_use(docs) -> set[str]:
    """Upper-cased secret/variable names that reach an id sink, in any workflow."""
    names = set()
    for doc in docs.values():
        if not isinstance(doc, dict):
            continue
        blocks = [doc.get("env")]
        for job in (doc.get("jobs") or {}).values():
            if not isinstance(job, dict):
                continue
            blocks.append(job.get("env"))
            for step in job_steps(job):
                _, covers, _ = mask_command(step)
                for key in ("env", "with"):
                    block = step.get(key)
                    if not isinstance(block, dict):
                        continue
                    for k, v in block.items():
                        if k == "role-to-assume" or is_sink_key(k) or (key == "env" and covers and k in covers):
                            names |= named_reads(v)
        for block in blocks:
            if isinstance(block, dict):
                for k, v in block.items():
                    if is_sink_key(k):
                        names |= named_reads(v)
    return names


# --- the check ----------------------------------------------------------------


class Result:
    def __init__(self):
        self.findings: list[tuple[str, int, str]] = []
        self.mask_steps = 0
        self.id_reads = 0
        self.id_names: set[str] = set()
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
    by_use = collect_ids_by_use(docs)

    def ident(name: str) -> bool:
        return is_id_name(name) or name.upper() in by_use

    for path, doc in docs.items():
        if not isinstance(doc, dict):
            continue
        rel = path.relative_to(root).as_posix()
        out: list[tuple[str, int, str]] = []
        sub = Result()
        check_workflow(root, rel, doc, ident, out, sub)
        res.findings.extend(out)
        res.mask_steps += sub.mask_steps
        res.id_reads += sub.id_reads
        res.id_names |= sub.id_names
    return res


def check_workflow(root, rel, doc, ident, out, res) -> None:
    def bad(line: int, msg: str) -> None:
        out.append((rel, line, msg))

    jobs = doc.get("jobs") if isinstance(doc.get("jobs"), dict) else {}
    guarded_vars: set[str] = set()     # vars.NAME compared against ''
    id_reads: dict[str, tuple[str, int]] = {}  # NAME -> (spelling, first line)
    wf_shell = shell_of(doc)

    def literal_ids(value, line):
        for text, ln in strings_with_lines(value, line, skip_keys=("uses",)):
            for pat, what in ((ARN_LITERAL, "an ARN naming an account"), (ID_LITERAL, "an account id")):
                for m in pat.finditer(text):
                    if not placeholder(m.group(1)):
                        bad(line_in(text, ln, m.start()),
                            f"carries {what} as a literal (not repeated here). A literal is printed "
                            "wherever it is used and kept in the public repository besides; it "
                            "belongs in a secret on the job's environment. Only the tree's "
                            "synthetic placeholders (one digit repeated, or 123456789012) may "
                            "appear in a workflow.")

    def scan(value, line, where: str, *, aws_job: bool, guards: set | None = None,
             entry: bool = False, is_if: bool = False) -> set[str]:
        """Apply rules 1-3 to every expression in value. Returns {id secret} read.

        entry: value is one step env/with entry, where an id secret may appear
        whole. guards: collects the secrets this job compares against ''."""
        found = set()
        for text, ln in strings_with_lines(value, line):
            whole = exact_expr(text)
            for expr, idx in expressions(text, is_if):
                at = line_in(text, ln, idx)
                toks = tokenize(expr)
                if toks is None:
                    if CONTEXT_WORDS.search(expr):
                        bad(at, f"has an expression in its {where} this gate cannot read "
                                f"({expr.strip()[:60]!r}) that mentions the secrets, vars or "
                                "inputs context. Write it in a form the gate can read, so it "
                                "can prove it names no account id or role ARN.")
                    continue
                rs = refs(toks)
                g = guard_ref(toks, rs)
                s = sole(toks, rs)
                for r in rs:
                    got = resolve(r)
                    if not got:
                        continue
                    ctx, name, problem = got
                    if problem:
                        how = "the whole" if problem == "whole" else "a computed index or filter of the"
                        bad(at, f"reads {how} `{ctx}` context in its {where} "
                                f"({expr.strip()[:60]!r}). This gate cannot tell what that "
                                "names, so it cannot prove it names no account id or role ARN; "
                                "a whole context printed or passed on carries every id in it. "
                                f"Read each value by its literal name (`{ctx}.NAME`).")
                        continue
                    key = name.upper()
                    if r is g and len(r.path) == 1 and ctx in ("secrets", "vars"):
                        if ctx == "vars":
                            guarded_vars.add(key)
                        elif guards is not None:
                            guards.add(key)
                        continue
                    if ctx == "inputs":
                        if ident(name):
                            bad(at, f"reads the input {name}, an AWS account id or role ARN. An "
                                    "input cannot be masked before it is printed; take it from "
                                    "a secret on the job's environment instead.")
                        continue
                    if ctx == "vars":
                        if ident(name):
                            bad(at, f"reads {name}, an AWS account id or role ARN, from "
                                    "`vars.` in its " + where + ". A variable is never masked: "
                                    "the runner prints it in the env block and the inputs of every "
                                    "step that receives it, before any step can mask it. Make it a "
                                    "secret on the GitHub Environment the job declares (see "
                                    "docs/operations.md); only the guard form "
                                    f"`${{{{ vars.{name} != '' }}}}` may name the variable.")
                        elif aws_job and key not in VARS_ALLOWED:
                            bad(at, f"reads the variable {name} in its {where}, in a job that can "
                                    "hold AWS credentials. Such a job reads no variable except in "
                                    "the guard form: a variable is printed unmasked, and one named "
                                    "outside the id naming rule (a state bucket, an account under "
                                    "another name) still carries an account id. Make it a secret, or "
                                    "add the name to VARS_ALLOWED with the reason it can never "
                                    "carry an id.")
                        continue
                    if not ident(name):
                        continue
                    res.id_reads += 1
                    res.id_names.add(key)
                    id_reads.setdefault(key, (name, at))
                    found.add(key)
                    whole_value = entry and whole is not None and whole == expr and s is r \
                        and len(r.path) == 1
                    if whole_value:
                        continue
                    if entry:
                        bad(at, f"computes from the id secret {name} in its {where} "
                                f"({expr.strip()[:60]!r}). The runner masks a secret only "
                                "whole: a value derived from it (fromJSON, toJSON, format, an "
                                "index, a concatenation) is printed in the clear in this step's "
                                "env block, before its first command can mask it. Pass "
                                f"`${{{{ secrets.{name} }}}}` whole, and cut pieces out in shell "
                                "after the mask command, handing them on as step outputs.")
                    else:
                        bad(at, f"passes the id secret {name} through its {where}. It may "
                                "reach a step only through that step's `env:` map or `with:` "
                                "inputs, whole, after the job's mask step: anywhere else it "
                                "reaches steps that run before the mask, or is expanded into "
                                "text where its pieces are printed unmasked.")
        return found

    def sink_check(key, value, line, where, mask_ids: set | None):
        """An id-named key takes only a whole secret, a mask-step output or a guard."""
        for text, ln in strings_with_lines(value, line):
            for expr, idx in expressions(text, False):
                if mask_ids is not None and whole_read_name(text) is not None:
                    continue
                if is_guard(text):
                    continue
                sid = step_output_whole(text)
                if mask_ids is not None and sid is not None and sid in mask_ids:
                    continue
                allowed = ("`${{ secrets.NAME }}` whole, an output of a mask step earlier in "
                           "this job, or the guard form") if mask_ids is not None else \
                    "only the guard form (a secret or a mask-step output cannot be here)"
                bad(line_in(text, ln, idx),
                    f"sets {key}, which by its name carries an account id or role ARN, from "
                    f"{expr.strip()[:60]!r} in its {where}. Such a key takes {allowed}: a "
                    "variable, an input, a matrix value or another job's output is printed "
                    "unmasked in this step's env block or inputs, whatever it is called.")

    # Workflow-level: triggers' inputs and everything but jobs.
    on = doc.get("on", doc.get(True))
    if isinstance(on, dict):
        for trig in ("workflow_dispatch", "workflow_call"):
            spec = on.get(trig)
            inputs = spec.get("inputs") if isinstance(spec, dict) else None
            if isinstance(inputs, LDict):
                for name in inputs:
                    if isinstance(name, str) and ident(name):
                        bad(inputs.key_lines.get(name, inputs.line),
                            f"declares the {trig} input '{name}', an AWS account id or "
                            "role ARN. An input is typed into the dispatch form, kept in the "
                            "run's event payload and printed in the env block of the first "
                            "step that reads it, so no step can mask it first. Take it from "
                            "a secret on the job's environment (or derive it from one).")
    literal_ids(doc, 1)
    for key in doc:
        if key in ("on", True, "jobs"):
            continue
        kl = doc.key_lines.get(key, 1)
        scan(doc[key], kl, f"workflow-level `{key}`", aws_job=False)
        if key == "env" and isinstance(doc[key], LDict):
            for k, v in doc[key].items():
                if is_sink_key(k):
                    sink_check(k, v, doc[key].value_lines.get(k, kl), "workflow-level `env`", None)

    no_env_guards: dict[str, set[str]] = {}  # job without environment -> secrets guarded
    env_reads: dict[str, tuple[str, int]] = {}  # job with environment -> (first id, line)
    for job_id, job in jobs.items():
        if not isinstance(job, LDict):
            continue
        job_line = jobs.key_lines.get(job_id, job.line)
        aws_job = holds_aws(doc, job)
        guards: set[str] = set()
        reads_value: dict[str, int] = {}  # id secret name -> first line in this job
        job_shell = shell_of(job)
        for key in job:
            if key == "steps":
                continue
            kl = job.key_lines.get(key, job.line)
            if key == "secrets" and isinstance(job[key], str) and job[key].strip().lower() == "inherit":
                bad(kl, f"job '{job_id}' passes `secrets: inherit`, which hands every "
                        "secret, account ids and role ARNs included, to a reusable workflow "
                        "this gate cannot read. Pass the secrets it needs by name.")
                continue
            for name in scan(job[key], job.value_lines.get(key, kl), f"job-level `{key}`",
                             aws_job=aws_job, guards=guards, is_if=(key == "if")):
                reads_value.setdefault(name, kl)
            if key == "env" and isinstance(job[key], LDict):
                for k, v in job[key].items():
                    if is_sink_key(k):
                        sink_check(k, v, job[key].value_lines.get(k, kl), "job-level `env`", None)

        masked: set[str] = set()
        mask_step_ids: set[str] = set()
        for step in job.get("steps") or []:
            if not isinstance(step, LDict):
                continue
            step_name = step.get("name", step.get("uses", "?"))
            receives: dict[str, list[tuple[str, int]]] = {}  # name -> [(where, line)]
            for key in step:
                kl = step.key_lines.get(key, step.line)
                vl = step.value_lines.get(key, kl)
                if key in ("env", "with") and isinstance(step[key], LDict):
                    block = step[key]
                    for k, v in block.items():
                        kline = block.key_lines.get(k, block.line)
                        for name in scan(v, block.value_lines.get(k, kline), f"`{key}.{k}`",
                                         aws_job=aws_job, guards=guards, entry=True):
                            receives.setdefault(name, []).append((f"{key}.{k}", kline))
                        if is_sink_key(k):
                            sink_check(k, v, block.value_lines.get(k, kline), f"`{key}`",
                                       mask_step_ids)
                else:
                    scan(step[key], vl, f"step `{key}`", aws_job=aws_job, guards=guards,
                         is_if=(key == "if"))
            for name, places in receives.items():
                reads_value.setdefault(name, places[0][1])

            run = step.get("run") if isinstance(step.get("run"), str) else None
            script, covers, offset = mask_command(step)
            cmd = first_command(run or "")[0]
            cmd_line = step.value_lines.get("run", step.line) + offset
            if script:
                res.mask_steps += 1
                ok = True
                if not (root / script).is_file():
                    bad(cmd_line, f"runs {script}, which is not in the tree, so nothing "
                                  "is masked.")
                    ok = False
                if "if" in step:
                    bad(step.key_lines["if"], f"job '{job_id}', mask step '{step_name}' has an "
                        "`if:`. A mask step runs whenever its job does: skipped, every later "
                        "step still receives the secret and nothing has masked its pieces.")
                    ok = False
                coe = step.get("continue-on-error")
                if coe is not None and str(coe).strip().lower() != "false":
                    bad(step.key_lines["continue-on-error"], f"job '{job_id}', mask step "
                        f"'{step_name}' sets `continue-on-error`. A mask step that fails must "
                        "stop the job: the masks may not have been registered.")
                    ok = False
                for shell, where, ln in ((step.get("shell"), "step", step.key_lines.get("shell")),
                                         (job_shell, "job's `defaults.run`", job.key_lines.get("defaults")),
                                         (wf_shell, "workflow's `defaults.run`", doc.key_lines.get("defaults"))):
                    if shell is not None and str(shell).strip() != "bash":
                        bad(ln or step.line, f"job '{job_id}', mask step '{step_name}' runs under "
                            f"the {where} shell {str(shell)[:30]!r}. The mask command is bash, "
                            "and only the default shell or `bash` (both `-e`) stops the step "
                            "when it fails; another shell runs on with nothing masked.")
                        ok = False
                    if shell is not None:
                        break
                env = step.get("env") if isinstance(step.get("env"), LDict) else LDict()
                for k in sorted(covers or ()):
                    if k not in env:
                        bad(cmd_line, f"job '{job_id}', mask step '{step_name}' names {k}, "
                                      "which this step's env does not carry, so it masks nothing "
                                      "for it.")
                        ok = False
                    elif whole_read_name(env[k]) is None:
                        bad(env.key_lines.get(k, env.line),
                            f"job '{job_id}', mask step '{step_name}' masks {k}, which holds "
                            f"{str(env[k])[:60]!r}. What a mask step masks, and what it hands on "
                            "as step outputs, is a secret read whole: anything else was printed "
                            "unmasked in this step's env block before the mask ran.")
                        ok = False
                if ok and isinstance(step.get("id"), str):
                    mask_step_ids.add(step["id"].lower())

            for name, places in receives.items():
                if name in masked:
                    if AFTER_FAILURE.search(str(step.get("if", ""))):
                        bad(step.key_lines["if"], f"job '{job_id}', step '{step_name}' receives "
                            f"{name} and runs after a failure ({str(step['if'])[:50]!r}). If a "
                            "step ahead of the mask step fails, the mask step is skipped and "
                            "this one runs with nothing masked.")
                    continue
                masked.add(name)
                env_keys = [w.split(".", 1)[1] for w, _ in places if w.startswith("env.")]
                with_places = [(w, ln) for w, ln in places if w.startswith("with.")]
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
                                  f'[--optional] {" ".join(env_keys)}`. Masks take effect from '
                                  "the line after `::add-mask::`, so anything before it can "
                                  "print a piece of the value.")
                else:
                    missing = [k for k in env_keys if k not in covers]
                    if missing:
                        bad(cmd_line, f"job '{job_id}', step '{step_name}': the mask "
                                      f"command does not name {', '.join(missing)}, which "
                                      f"carries {name} into this step, so its pieces are "
                                      "never masked.")

            w = step.get("with")
            if isinstance(w, LDict) and "role-to-assume" in w:
                v = w["role-to-assume"]
                ln = w.key_lines.get("role-to-assume", w.line)
                sid = step_output_whole(v)
                if not (whole_read_name(v) is not None or (sid is not None and sid in mask_step_ids)):
                    bad(ln, f"job '{job_id}': role-to-assume is {str(v)[:60]!r}. It must be "
                            "`${{ secrets.NAME }}`, read after the job's mask step, or "
                            "`${{ steps.ID.outputs.X }}` from that mask step. The action "
                            "prints this input, so a variable, matrix value, input or literal "
                            "here publishes the role ARN and its account id.")
            if uses_configure_aws(step):
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
        if job.get("environment"):
            for name, ln in reads_value.items():
                env_reads.setdefault(f"{job_id}\0{name}", (name, ln))
        else:
            no_env_guards[job_id] = guards

    # Rule 4: a no-environment job this one needs refuses the inherited secret.
    def needs_of(job_id: str) -> set[str]:
        seen, todo = set(), [job_id]
        while todo:
            j = jobs.get(todo.pop())
            n = j.get("needs") if isinstance(j, dict) else None
            for dep in ([n] if isinstance(n, str) else n if isinstance(n, list) else []):
                if isinstance(dep, str) and dep not in seen:
                    seen.add(dep)
                    todo.append(dep)
        return seen

    for key, (name, ln) in sorted(env_reads.items(), key=lambda kv: kv[1][1]):
        job_id = key.split("\0", 1)[0]
        if not any(name in no_env_guards.get(dep, ()) for dep in needs_of(job_id)):
            bad(ln, f"job '{job_id}' reads the id secret {name} from its environment, but no "
                    f"job it needs, with no environment, compares `secrets.{name}` against ''. "
                    "The secrets context falls back from the environment to the repository and "
                    "the organization, so a value stored at repository level (a migration that "
                    "left off --env) is read here, and by every workflow in the repository, "
                    "while the run stays green. Add a refuse-inherited-config job with no "
                    "environment and `permissions: {}` that fails when "
                    f"`${{{{ secrets.{name} != '' }}}}`, and make this job need it.")

    for key, (name, ln) in sorted(id_reads.items(), key=lambda kv: kv[1][1]):
        if key not in guarded_vars:
            bad(ln, f"reads the id secret {name}, and nothing in this workflow compares "
                    f"`vars.{name}` against ''. A value left behind as a variable from before "
                    "it became a secret must fail the run (it is never masked, and the next "
                    f"edit that reads it prints it): add `${{{{ vars.{name} != '' }}}}` to "
                    "the env of the first step that receives the secret, and fail on true.")


def report(res: Result) -> int:
    if res.findings:
        for rel, line, msg in res.findings:
            print(f"::error file={rel},line={line}::{rel}:{line}: {msg}")
        print(f"\n{len(res.findings)} finding(s). See the docstring of "
              "scripts/check-workflow-id-masking.py and docs/operations.md.")
        return 1
    print(f"OK: {res.workflows} workflow(s) read; {res.id_reads} id secret read(s) of "
          f"{len(res.id_names)} name(s), each masked first by one of {res.mask_steps} mask "
          "step(s), none from vars.")
    return 0


def main_check() -> int:
    ok, why = repo_is_visible(ROOT)
    if not ok:
        print(f"::error::{why} Refusing to report a pass.")
        return 1
    res = check(ROOT)
    unseen = sorted(KNOWN_ID_READS - res.id_names)
    if res.workflows < MIN_WORKFLOWS or res.mask_steps < MIN_MASK_STEPS or unseen:
        print(f"::error::read {res.workflows} workflow(s) and {res.mask_steps} mask step(s) "
              f"under .github/workflows (expected at least {MIN_WORKFLOWS} and "
              f"{MIN_MASK_STEPS}), and saw no read of "
              f"{', '.join(unseen) or 'nothing missing'} among the id secrets the workflows "
              "read today. This gate did not see what it checks and refuses to report a pass.")
        return 1
    return report(res)


# --- self-test ----------------------------------------------------------------

DEPLOY_VERIFY_ENV = ("          DEPLOY_ACCOUNT_ID: ${{ secrets.DEPLOY_ACCOUNT_ID }}\n"
                     "          TARGET_ENV: ${{ inputs.environment }}\n        run: |\n"
                     "          if ! caller_account")
DEPLOY_MASK_STEP = "      - name: Require DEPLOY_ROLE_ARN, DEPLOY_ACCOUNT_ID and a matching leaf\n"
DEPLOY_MASK_STEP_ENV = DEPLOY_MASK_STEP + "        env:\n"
E2E_MASK_STEP = "      - name: Mask and check E2E_AWS_ROLE_ARN\n        id: role\n"
E2E_MASK_CMD = 'bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" --optional E2E_AWS_ROLE_ARN\n'
CI_DETECT_ENV = ("          AWS_ROLE_ARN: ${{ secrets.AWS_ROLE_ARN }}\n"
                 "          TERRAGRUNT_ACCOUNT_ID: ${{ secrets.TERRAGRUNT_ACCOUNT_ID }}\n"
                 "          ROLE_ARN_VARIABLE")
DEPLOY_RUN_TG_ENV = ("          TERRAGRUNT_ACCOUNT_ID: ${{ secrets.DEPLOY_ACCOUNT_ID }}\n"
                     "          COMPONENT: ${{ inputs.component }}\n          ACTION")

# (name, file, old, new, expected line: None = a changed line inside `new`, or
# a regex naming the line in the mutated file the finding must cite). old and
# new may be tuples of the same length, each pair applied once, with a regex.
MUTATIONS = [
    ("role-to-assume from a variable", "deploy.yml",
     "role-to-assume: ${{ secrets.DEPLOY_ROLE_ARN }}",
     "role-to-assume: ${{ vars.DEPLOY_ROLE_ARN }}", None),
    ("a variable in a later step's env", "deploy.yml", DEPLOY_VERIFY_ENV,
     DEPLOY_VERIFY_ENV.replace("secrets.DEPLOY_ACCOUNT_ID", "vars.DEPLOY_ACCOUNT_ID"), None),
    ("a variable read with index syntax", "deploy.yml", DEPLOY_VERIFY_ENV,
     DEPLOY_VERIFY_ENV.replace("secrets.DEPLOY_ACCOUNT_ID", "vars['DEPLOY_ACCOUNT_ID']"), None),
    ("a variable read through a mixed-case context name", "deploy.yml", DEPLOY_VERIFY_ENV,
     DEPLOY_VERIFY_ENV.replace("secrets.DEPLOY_ACCOUNT_ID", "Vars.DEPLOY_ACCOUNT_ID"), None),
    ("a variable read through a computed index", "deploy.yml",
     "          aws-region: ${{ inputs.region }}\n          # Already masked by the guard step",
     ("          aws-region: ${{ inputs.region }}\n"
      "          role-session-name: ${{ vars[format('DEPLOY_{0}', 'ACCOUNT_ID')] }}\n"
      "          # Already masked by the guard step"), None),
    ("a step receives the secret before the mask step", "deploy.yml", DEPLOY_MASK_STEP,
     ("      - name: Early\n        env:\n          EARLY: ${{ secrets.DEPLOY_ACCOUNT_ID }}\n"
      "        run: echo early\n" + DEPLOY_MASK_STEP), None),
    ("an early step reads the secret with index syntax", "deploy.yml", DEPLOY_MASK_STEP,
     ("      - name: Early\n        env:\n          EARLY: ${{ secrets['DEPLOY_ROLE_ARN'] }}\n"
      "        run: echo \"${EARLY#arn:aws:iam::}\"\n" + DEPLOY_MASK_STEP), None),
    ("an early step reads the secret through a mixed-case context name", "deploy.yml",
     DEPLOY_MASK_STEP,
     ("      - name: Early\n        env:\n          EARLY: ${{ Secrets.DEPLOY_ROLE_ARN }}\n"
      "        run: echo \"${EARLY#arn:aws:iam::}\"\n" + DEPLOY_MASK_STEP), None),
    ("an early step reads every variable at once", "deploy.yml", DEPLOY_MASK_STEP,
     ("      - name: Early\n        env:\n          ALL: ${{ toJSON(vars) }}\n"
      "        run: echo early\n" + DEPLOY_MASK_STEP), None),
    ("every secret in a job-level env", "e2e.yml",
     "    environment: e2e\n", "    environment: e2e\n    env:\n      ALL: ${{ toJSON(secrets) }}\n",
     None),
    ("the mask is not the first command", "destroy.yml",
     '        run: |\n          bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" --optional DEPLOY_ROLE_ARN DEPLOY_ACCOUNT_ID\n',
     '        run: |\n          echo "starting"\n          bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" --optional DEPLOY_ROLE_ARN DEPLOY_ACCOUNT_ID\n',
     None),
    ("the mask step is conditional", "deploy.yml", DEPLOY_MASK_STEP_ENV,
     DEPLOY_MASK_STEP + "        if: github.event_name == 'push'\n        env:\n", None),
    ("the mask step continues on error", "deploy.yml", DEPLOY_MASK_STEP_ENV,
     DEPLOY_MASK_STEP + "        continue-on-error: true\n        env:\n", None),
    ("the mask step runs under pwsh", "e2e.yml", E2E_MASK_STEP,
     E2E_MASK_STEP + "        shell: pwsh\n", None),
    ("the job's default shell does not stop on failure", "e2e.yml",
     "    environment: e2e\n", "    environment: e2e\n    defaults:\n      run:\n        shell: bash {0}\n",
     None),
    ("the mask command carries an argument the script refuses", "e2e.yml", E2E_MASK_CMD,
     E2E_MASK_CMD.replace("E2E_AWS_ROLE_ARN\n", "E2E_AWS_ROLE_ARN --bogus\n"), None),
    ("--optional after a name", "e2e.yml", E2E_MASK_CMD,
     E2E_MASK_CMD.replace("--optional E2E_AWS_ROLE_ARN", "E2E_AWS_ROLE_ARN --optional"), None),
    ("a receiving step runs after a failure", "deploy.yml",
     "      - name: Verify the credential is in DEPLOY_ACCOUNT_ID's account\n",
     "      - name: Verify the credential is in DEPLOY_ACCOUNT_ID's account\n        if: always()\n",
     None),
    ("the guard job reads the secret's value", "destroy.yml",
     "INHERITED_ROLE_ARN_SECRET: ${{ secrets.DEPLOY_ROLE_ARN != '' }}",
     "INHERITED_ROLE_ARN_SECRET: ${{ secrets.DEPLOY_ROLE_ARN }}", None),
    ("the repository-level secret guard removed", "ci.yml",
     "INHERITED_ROLE_ARN_SECRET: ${{ secrets.AWS_ROLE_ARN != '' }}",
     "INHERITED_ROLE_ARN_SECRET: \"false\"",
     r"^\s+AWS_ROLE_ARN: \$\{\{ secrets\.AWS_ROLE_ARN \}\}"),
    ("the mask command omits a secret the step receives", "ci.yml",
     "--optional AWS_ROLE_ARN TERRAGRUNT_ACCOUNT_ID\n",
     "--optional AWS_ROLE_ARN\n", None),
    ("a piece of the secret computed in the mask step's env", "ci.yml", CI_DETECT_ENV,
     CI_DETECT_ENV.replace("          ROLE_ARN_VARIABLE",
                           "          DEV_ROLE_ARN: ${{ fromJSON(secrets.AWS_ROLE_ARN).development }}\n"
                           "          ROLE_ARN_VARIABLE"), None),
    ("the secret re-serialised in a later step's env", "ci.yml",
     "          TERRAGRUNT_ACCOUNT_ID: ${{ secrets.TERRAGRUNT_ACCOUNT_ID }}\n        run: terragrunt plan",
     "          TERRAGRUNT_ACCOUNT_ID: ${{ toJSON(secrets.TERRAGRUNT_ACCOUNT_ID) }}\n        run: terragrunt plan",
     None),
    ("the secret expanded into run text", "ci.yml",
     "        run: terragrunt plan -lock=false -no-color\n",
     "        run: terragrunt plan -lock=false -no-color -var account=${{ secrets.TERRAGRUNT_ACCOUNT_ID }}\n",
     None),
    ("role-to-assume from the matrix", "ci.yml",
     "role-to-assume: ${{ secrets.AWS_ROLE_ARN }}",
     "role-to-assume: ${{ matrix.role_arn }}", None),
    ("an id-named key fed from a variable of another name", "ci.yml",
     "          TERRAGRUNT_ACCOUNT_ID: ${{ secrets.TERRAGRUNT_ACCOUNT_ID }}\n        run: terragrunt plan",
     "          TERRAGRUNT_ACCOUNT_ID: ${{ vars.AWS_ACCOUNT }}\n        run: terragrunt plan", None),
    ("the secret in a workflow-level env", "ci.yml",
     "permissions:\n  contents: read\n\njobs:\n",
     "permissions:\n  contents: read\n\nenv:\n  TERRAGRUNT_ACCOUNT_ID: ${{ secrets.TERRAGRUNT_ACCOUNT_ID }}\n\njobs:\n",
     None),
    ("the secret in a job-level env", "e2e.yml",
     "    environment: e2e\n",
     "    environment: e2e\n    env:\n      E2E_AWS_ROLE_ARN: ${{ secrets.E2E_AWS_ROLE_ARN }}\n", None),
    ("the mask step masks a variable it hands on as an output", "e2e.yml",
     "          E2E_AWS_ROLE_ARN: ${{ secrets.E2E_AWS_ROLE_ARN }}\n          ROLE_ARN_VARIABLE",
     "          E2E_AWS_ROLE_ARN: ${{ vars.E2E_ROLE }}\n          ROLE_ARN_VARIABLE", None),
    ("an account id as a dispatch input", "e2e.yml",
     "      region:\n        description: \"Region\"\n",
     ("      account_id:\n        description: \"Target AWS account ID\"\n"
      "      region:\n        description: \"Region\"\n"), None),
    ("an account as a dispatch input under another name", "e2e.yml",
     "      region:\n        description: \"Region\"\n",
     ("      aws_account:\n        description: \"Target AWS account (12 digits)\"\n"
      "      region:\n        description: \"Region\"\n"), None),
    ("an id input read through github.event.inputs with index syntax", "e2e.yml",
     "          E2E_REGION: ${{ inputs.region }}\n",
     "          E2E_REGION: ${{ inputs.region }}\n          ACCT: ${{ github.event.inputs['account_id'] }}\n",
     None),
    ("an id input read through an upper-case context name", "e2e.yml",
     "          E2E_REGION: ${{ inputs.region }}\n",
     "          E2E_REGION: ${{ inputs.region }}\n          ACCT: ${{ INPUTS.account_id }}\n", None),
    ("every leftover-variable guard removed", "e2e.yml",
     ("ROLE_ARN_VARIABLE: ${{ vars.E2E_AWS_ROLE_ARN != '' }}",
      "INHERITED_VARIABLE: ${{ vars.E2E_AWS_ROLE_ARN != '' }}"),
     ("ROLE_ARN_VARIABLE: \"false\"", "INHERITED_VARIABLE: \"false\""),
     r"^\s+E2E_AWS_ROLE_ARN: \$\{\{ secrets\.E2E_AWS_ROLE_ARN \}\}"),
    ("an action is the first step to receive the secret", "e2e.yml",
     "          E2E_AWS_ROLE_ARN: ${{ secrets.E2E_AWS_ROLE_ARN }}\n          ROLE_ARN_VARIABLE",
     "          E2E_AWS_ROLE_ARN: ${{ steps.none.outputs.none }}\n          ROLE_ARN_VARIABLE",
     r"^\s+role-to-assume: \$\{\{ secrets\.E2E_AWS_ROLE_ARN \}\}"),
    ("a literal account id", "deploy.yml", DEPLOY_RUN_TG_ENV,
     DEPLOY_RUN_TG_ENV.replace("${{ secrets.DEPLOY_ACCOUNT_ID }}", '"222233334444"'), None),
    ("a variable of a name outside the rule in an AWS job", "deploy.yml", DEPLOY_RUN_TG_ENV,
     DEPLOY_RUN_TG_ENV.replace("          ACTION",
                               "          BUCKET: ${{ vars.TF_BUCKET }}\n          ACTION"), None),
    ("configure-aws-credentials without mask-aws-account-id", "deploy.yml",
     "          mask-aws-account-id: true\n", "",
     r"^\s+uses: aws-actions/configure-aws-credentials@"),
    ("configure-aws-credentials spelt in mixed case, unmasked", "destroy.yml",
     ("        uses: aws-actions/configure-aws-credentials@", "          mask-aws-account-id: true\n"),
     ("        uses: Aws-Actions/Configure-AWS-Credentials@", ""),
     r"^\s+uses: Aws-Actions/Configure-AWS-Credentials@"),
    ("secrets: inherit", "e2e.yml",
     "    environment: e2e\n", "    environment: e2e\n    secrets: inherit\n", None),
]


# drift.yml: the role map is a secret on the drift environment, masked by
# `mask-aws-ids.sh DRIFT_PLAN_ROLE_ARNS` in each of the two jobs that read it.
# Always applied: drift.yml is held to every rule like the other workflows.
DRIFT_MUTATIONS = [
    ("drift: the role map masked by a script other than mask-aws-ids.sh", "drift.yml",
     '          bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" DRIFT_PLAN_ROLE_ARNS\n\n'
     '          # The same role-ARN shape',
     '          bash "$GITHUB_WORKSPACE/scripts/mask-drift-role-map.sh"\n\n'
     '          # The same role-ARN shape', None),
    ("drift: the mask step names a variable other than the role map", "drift.yml",
     '          bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" DRIFT_PLAN_ROLE_ARNS\n\n'
     '          # The same role-ARN shape',
     '          bash "$GITHUB_WORKSPACE/scripts/mask-aws-ids.sh" ACCOUNT_DIR\n\n'
     '          # The same role-ARN shape', None),
    ("drift: the role map reaches a step before the mask step", "drift.yml",
     "          persist-credentials: false\n\n      # The first step that receives the secret.",
     "          persist-credentials: false\n        env:\n"
     "          DRIFT_PLAN_ROLE_ARNS: ${{ secrets.DRIFT_PLAN_ROLE_ARNS }}\n\n"
     "      # The first step that receives the secret.", None),
    ("drift: something prints ahead of the role-map mask", "drift.yml",
     "        run: |\n          # First: mask every id and role ARN",
     "        run: |\n          echo \"selecting\"\n          # First: mask every id and role ARN", None),
    ("drift: role-to-assume from the matrix", "drift.yml",
     "role-to-assume: ${{ steps.role.outputs.role_arn }}",
     "role-to-assume: ${{ matrix.role_arn }}", None),
    ("drift: the guard job reads the variable's value", "drift.yml",
     "INHERITED_VARIABLE: ${{ vars.DRIFT_PLAN_ROLE_ARNS != '' }}",
     "INHERITED_VARIABLE: ${{ vars.DRIFT_PLAN_ROLE_ARNS }}", None),
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
        shutil.copy(ROOT / "scripts" / "mask-aws-ids.sh", base / "scripts" / "mask-aws-ids.sh")

        clean = check(base)
        if clean.findings:
            print("FAIL [unmutated]: the gate rejects the workflows as they are:", file=sys.stderr)
            for rel, ln, msg in clean.findings:
                print(f"  {rel}:{ln}: {msg[:120]}", file=sys.stderr)
            return 1
        unseen = KNOWN_ID_READS - clean.id_names
        if unseen:
            print(f"FAIL [unmutated]: no read of {', '.join(sorted(unseen))} was seen",
                  file=sys.stderr)
            return 1

        mutations = MUTATIONS + DRIFT_MUTATIONS
        for name, fname, old, new, expect in mutations:
            ran += 1
            target = base / WORKFLOWS_REL / fname
            text = target.read_text()
            pairs = list(zip(old, new)) if isinstance(old, tuple) else [(old, new)]
            mutated, missing = text, None
            for o, n in pairs:
                if mutated.count(o) != 1:
                    missing = (o, mutated.count(o))
                    break
                mutated = mutated.replace(o, n)
            if missing:
                print(f"FAIL [{name}]: anchor {missing[0][:50]!r} found {missing[1]} "
                      f"time(s) in {fname}", file=sys.stderr)
                failures += 1
                continue
            target.write_text(mutated)
            try:
                res = check(base)
            finally:
                target.write_text(text)
            rel = f"{WORKFLOWS_REL}/{fname}"
            lines = mutated.splitlines()
            if expect is None:
                # The lines of `new` that differ from `old`.
                start = mutated.index(new) if new else 0
                first = mutated.count("\n", 0, start) + 1
                old_lines = set(old.splitlines())
                wanted = {first + i for i, ln in enumerate(new.splitlines()) if ln not in old_lines} \
                    or {first}
            else:
                wanted = {i + 1 for i, ln in enumerate(lines) if re.search(expect, ln)}
            cited = {ln for r, ln, _ in res.findings if r == rel}
            if not res.findings:
                print(f"FAIL [{name}]: not rejected", file=sys.stderr)
                failures += 1
            elif not (cited & wanted):
                print(f"FAIL [{name}]: rejected, but cited {sorted(cited) or 'no line'} in "
                      f"{rel}, not the mutated line(s) {sorted(wanted)}", file=sys.stderr)
                for r, ln, msg in res.findings:
                    print(f"    {r}:{ln}: {msg[:110]}", file=sys.stderr)
                failures += 1
            else:
                hit = next(f for f in res.findings if f[0] == rel and f[1] in wanted)
                print(f"ok [{name}]: {hit[0]}:{hit[1]}: {hit[2][:90]}")
    if failures:
        print(f"check-workflow-id-masking self-test FAILED: {failures} of {ran} mutation(s)",
              file=sys.stderr)
        return 1
    if ran < len(MUTATIONS) + len(DRIFT_MUTATIONS):
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
