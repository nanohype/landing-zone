#!/usr/bin/env python3
"""Cross-check every Terragrunt dependency mock against its target component's real outputs.

Terragrunt `dependency` blocks in live/_envcommon/aws/*.hcl carry `mock_outputs` so
credential-less `validate`/`plan`/`render` can resolve without reading remote state.
A mock is only safe if every key it declares is an output the target component actually
exports — otherwise a `dependency.<name>.outputs.<key>` reference silently resolves to a
stale mock value that never matches reality, and a renamed output slips through every
gate. This script fails the build when a mock key is not a declared output of the
component the dependency points at.

Resolution: `config_path = "../<component>"` -> `components/aws/<component>/outputs.tf`.
Dependencies whose target component outputs.tf cannot be located are reported and skipped
(config_path correctness is separately enforced by the terragrunt-evaluate CI job).

No third-party deps — brace-aware line parsing over the repo's uniform HCL.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENVCOMMON = os.path.join(REPO, "live", "_envcommon", "aws")
COMPONENTS = os.path.join(REPO, "components", "aws")

OUTPUT_RE = re.compile(r'^\s*output\s+"([A-Za-z0-9_]+)"\s*\{')
CONFIG_PATH_RE = re.compile(r'^\s*config_path\s*=\s*"([^"]*)"')
KEY_RE = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=')
DEP_START_RE = re.compile(r'^dependency\s+"([A-Za-z0-9_-]+)"\s*\{')


def component_outputs(component):
    """Declared output names for components/aws/<component>, or None if not found."""
    path = os.path.join(COMPONENTS, component, "outputs.tf")
    if not os.path.isfile(path):
        return None
    names = set()
    with open(path) as fh:
        for line in fh:
            m = OUTPUT_RE.match(line)
            if m:
                names.add(m.group(1))
    return names


def iter_blocks(lines):
    """Yield (dep_name, block_lines) for each top-level dependency block."""
    i, n = 0, len(lines)
    while i < n:
        m = DEP_START_RE.match(lines[i])
        if not m:
            i += 1
            continue
        depth = lines[i].count("{") - lines[i].count("}")
        block = [lines[i]]
        j = i + 1
        while j < n and depth > 0:
            block.append(lines[j])
            depth += lines[j].count("{") - lines[j].count("}")
            j += 1
        yield m.group(1), block
        i = j


def mock_keys(block):
    """Top-level keys inside a dependency block's `mock_outputs = { ... }`."""
    keys, in_mock, depth = [], False, 0
    for line in block:
        if not in_mock:
            if re.match(r"^\s*mock_outputs\s*=\s*\{", line):
                in_mock = True
                depth = line.count("{") - line.count("}")
            continue
        before = depth
        depth += line.count("{") - line.count("}")
        if before == 1:  # only capture keys at the mock_outputs top level
            km = KEY_RE.match(line)
            if km:
                keys.append(km.group(1))
        if depth <= 0:
            break
    return keys


def main():
    errors, skips, checked = [], [], 0
    for fname in sorted(os.listdir(ENVCOMMON)):
        if not fname.endswith(".hcl"):
            continue
        path = os.path.join(ENVCOMMON, fname)
        lines = open(path).read().split("\n")
        for dep_name, block in iter_blocks(lines):
            cfg = next((CONFIG_PATH_RE.match(l).group(1) for l in block
                        if CONFIG_PATH_RE.match(l)), None)
            keys = mock_keys(block)
            if cfg is None or not keys:
                continue
            component = cfg.rstrip("/").split("/")[-1]
            outputs = component_outputs(component)
            if outputs is None:
                skips.append(f"{fname}: dependency \"{dep_name}\" -> component "
                             f"'{component}' has no components/aws/{component}/outputs.tf "
                             f"(config_path={cfg}); mock keys unverified")
                continue
            for key in keys:
                checked += 1
                if key not in outputs:
                    errors.append(
                        f"{fname}: dependency \"{dep_name}\" mocks '{key}', which is not "
                        f"an output of component '{component}'. "
                        f"Declared outputs: {', '.join(sorted(outputs)) or '(none)'}")

    for s in skips:
        print(f"NOTE  {s}")
    if errors:
        print(f"\nFAIL  {len(errors)} stale mock key(s) — a mock references an output the "
              f"target component does not export:\n")
        for e in errors:
            print(f"  - {e}")
        print("\nFix the mock_outputs key (and the matching dependency.<name>.outputs.<key> "
              "reference) to a real output, or rename the component output back.")
        return 1
    print(f"OK    {checked} mock key(s) across every dependency match a declared "
          f"component output.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
