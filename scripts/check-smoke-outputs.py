#!/usr/bin/env python3
"""Cross-check every component smoke test's output reads against the component's real outputs.

Each `components/<cloud>/<component>/smoke-test.sh` asserts a deployed component against
live AWS, and it gets its inputs by reading `outputs.json` — the component's `tofu output
-json` — through `jq`. A read is only safe if the key it names is an output the component
actually exports: `jq -r '.missing_key.value'` yields the string "null" instead of failing,
so the script sails past the read and asserts against garbage. Every downstream check then
either passes vacuously or fails for a reason that has nothing to do with the infrastructure.
This script fails the build when a smoke test reads a key the component does not export.

Resolution: `components/<cloud>/<component>/smoke-test.sh` -> the `outputs.tf` beside it.

Only the top-level output name is verified — the `<name>` in `.<name>.value`. Nested field
access (`.tenant_outputs.value["$TENANT"].aurora_endpoint`) reaches into a map whose shape
lives in a tenant submodule, which is out of reach of a name check at this layer.

The parser is deliberately intolerant: anything in a smoke test that touches `outputs.json`
and does not resolve to a recognized `jq` read is reported as a failure, not skipped. A gate
that goes quiet when it stops understanding its input is worse than no gate at all.

No third-party deps — line-oriented parsing over the repo's uniform shell.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COMPONENTS = os.path.join(REPO, "components")

OUTPUT_RE = re.compile(r'^\s*output\s+"([A-Za-z0-9_]+)"\s*\{')
# A jq invocation reading outputs.json, filter in single or double quotes. The double-quoted
# form carries escaped quotes (".tenant_outputs.value[\"${TENANT}\"]..."), so its body match
# has to step over backslash escapes rather than stop at the first quote.
JQ_SINGLE_RE = re.compile(r"jq\s+(?:-[A-Za-z-]+\s+)*'([^']*)'\s+outputs\.json")
JQ_DOUBLE_RE = re.compile(r'jq\s+(?:-[A-Za-z-]+\s+)*"((?:[^"\\]|\\.)*)"\s+outputs\.json')
# `.<name>.value` — the top-level output a filter reads. Anchored on a leading dot so the
# `.value` inside `to_entries[] | "\(.key) \(.value)"` is not mistaken for an output name.
REF_RE = re.compile(r"\.([A-Za-z0-9_]+)\.value")
LEAD_REF_RE = re.compile(r"^\s*\.([A-Za-z0-9_]+)\.value")
# `tofu output -json > outputs.json` writes the file rather than reading it; nothing to check.
REDIRECT_RE = re.compile(r">\s*outputs\.json")


def smoke_tests():
    """Every components/<cloud>/<component>/smoke-test.sh, sorted."""
    found = []
    for cloud in sorted(os.listdir(COMPONENTS)):
        cloud_dir = os.path.join(COMPONENTS, cloud)
        if not os.path.isdir(cloud_dir):
            continue
        for component in sorted(os.listdir(cloud_dir)):
            path = os.path.join(cloud_dir, component, "smoke-test.sh")
            if os.path.isfile(path):
                found.append((f"{cloud}/{component}", path))
    return found


def component_outputs(script_path):
    """Declared output names for the component owning a smoke test, or None if not found."""
    path = os.path.join(os.path.dirname(script_path), "outputs.tf")
    if not os.path.isfile(path):
        return None
    names = set()
    with open(path) as fh:
        for line in fh:
            m = OUTPUT_RE.match(line)
            if m:
                names.add(m.group(1))
    return names


def read_refs(script_path):
    """(refs, parse_errors) for one smoke test.

    refs is a list of (line_number, output_name). parse_errors holds every line that touches
    outputs.json in a shape this parser does not recognize.
    """
    refs, parse_errors = [], []
    with open(script_path) as fh:
        for lineno, line in enumerate(fh, start=1):
            if "outputs.json" not in line:
                continue
            if line.lstrip().startswith("#"):
                continue
            if "jq" not in line:
                if REDIRECT_RE.search(line):
                    continue  # produces outputs.json, does not read it
                parse_errors.append(
                    f"line {lineno}: touches outputs.json outside a jq filter, so the "
                    f"output keys it reads cannot be verified: {line.strip()}")
                continue
            filters = JQ_SINGLE_RE.findall(line) + JQ_DOUBLE_RE.findall(line)
            if not filters:
                parse_errors.append(
                    f"line {lineno}: jq reads outputs.json but the filter did not parse "
                    f"(expected a quoted filter immediately before the filename): "
                    f"{line.strip()}")
                continue
            for flt in filters:
                if not LEAD_REF_RE.match(flt):
                    parse_errors.append(
                        f"line {lineno}: jq filter does not start with a `.<output>.value` "
                        f"reference, so its output key is unknown: {flt}")
                    continue
                for name in REF_RE.findall(flt):
                    refs.append((lineno, name))
    return refs, parse_errors


def main():
    errors, checked = [], 0
    scripts = smoke_tests()
    if not scripts:
        print("FAIL  no components/*/*/smoke-test.sh found — the gate is looking in the "
              "wrong place, not passing.")
        return 1

    for name, path in scripts:
        rel = os.path.relpath(path, REPO)
        outputs = component_outputs(path)
        if outputs is None:
            errors.append(f"{rel}: component '{name}' has no outputs.tf beside its smoke "
                          f"test, so nothing it reads can be verified")
            continue
        if not outputs:
            errors.append(f"{rel}: components/{name}/outputs.tf declares no outputs — "
                          f"either the file is unparseable or the smoke test reads a "
                          f"component that exports nothing")
            continue
        refs, parse_errors = read_refs(path)
        for pe in parse_errors:
            errors.append(f"{rel}: {pe}")
        if not refs and not parse_errors:
            errors.append(f"{rel}: no `.<output>.value` read found — a smoke test that "
                          f"never reads its component's outputs is either dead or parsed "
                          f"wrong")
            continue
        for lineno, key in refs:
            checked += 1
            if key not in outputs:
                errors.append(
                    f"{rel}:{lineno}: reads '{key}', which is not an output of component "
                    f"'{name}'. Declared outputs: {', '.join(sorted(outputs))}")

    if errors:
        print(f"FAIL  {len(errors)} smoke-test output problem(s) — a smoke test reads a key "
              f"the component does not export, or reads it in a shape this gate cannot "
              f"verify:\n")
        for e in errors:
            print(f"  - {e}")
        print("\nPoint the read at a declared output (or drop the assertion if the component "
              "does not own that resource), and keep every outputs.json read in the "
              "`jq -r '.<output>.value...' outputs.json` form this gate parses.")
        return 1
    print(f"OK    {checked} smoke-test output read(s) across {len(scripts)} script(s) match "
          f"a declared component output.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
