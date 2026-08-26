#!/usr/bin/env bash
# Zero-placeholder gate — fail if an unfilled "fill-me" sentinel appears in
# applied deploy configuration (Helm values, kustomize, ArgoCD manifests,
# terragrunt/tofu inputs). Every per-environment value must render from its
# source of truth, never sit in the repo as a placeholder waiting to be
# hand-edited before deploy.
#
# NOT sentinels (intentional public-repo conventions, deliberately unmatched):
#   - example.com domains
#   - the 111111111111 / 222222222222 fake AWS account ids
# Excluded by path: docs (prose, not applied config — *.md isn't scanned),
# examples, test fixtures, vendored copies, and the opt-in mcp-tunnel addon
# (user-supplied Cloudflare IDs, off by default).
set -uo pipefail

# Anchor to the repository root. Without this the scan is relative to whatever
# directory the caller happened to be in, so running it from a subdirectory
# quietly examines a fraction of the tree and reports the same success.
cd "$(dirname "$0")/.."

SENTINELS='PLACEHOLDER|REPLACE_ME|REPLACEME|CHANGEME|CHANGE_ME|FILL_ME|FILLME|TODO_FILL|TO_BE_FILLED|<FILL|<YOUR_|<ACCOUNT_ID>|<FLEET_ACCOUNT'

# stderr is NOT redirected. It was, and that is half of why an absent grep was
# silent as well as blind: the shell's "command not found" went to /dev/null
# along with the unreadable-file warnings it was meant to hide.
hits=$(grep -rnE "$SENTINELS" . \
  --include='*.yaml' --include='*.yml' --include='*.tf' --include='*.hcl' \
  --include='*.tfvars' --include='*.json' \
  --exclude='*.example' \
  --exclude-dir='.git' --exclude-dir='.terraform' --exclude-dir='.terragrunt-cache' \
  --exclude-dir='node_modules' --exclude-dir='examples' --exclude-dir='testdata' \
  --exclude-dir='test' --exclude-dir='mcp-tunnel' --exclude-dir='vendor')
grep_status=$?

# grep answers with FOUR values and the test below reads TWO. 0 is a match, 1 is
# a definite no-match, 2 is "could not read what you asked about", and 127 is
# "grep is not here". Only the first two are verdicts. The other two produce an
# empty result, and an empty result is this gate's PASSING value — so without
# this, a grep that CANNOT match is indistinguishable from one that found
# nothing, and the gate reports a clean tree by not running.
#
# Require the definite outcome; fail on anything else and name the status.
if [ "$grep_status" -ne 0 ] && [ "$grep_status" -ne 1 ]; then
  echo "FAIL: the scan did not run — grep exited ${grep_status}." >&2
  echo "127 means grep is not on PATH; 2 means it could not read part of the" >&2
  echo "tree. Either way nothing was examined, and an empty result here is the" >&2
  echo "passing value, so this cannot be reported as a clean tree." >&2
  exit 1
fi

# Anti-vacuity floor. A grep that matches nothing and a grep that CANNOT match
# print the same thing — success — and the second is how this gate dies without a
# sound: an include glob that stops matching, a tree that moved, a wrong cwd.
# Count what was actually examined and refuse to report a pass over too little.
#
# The floor sits below the real count rather than at it, so adding or removing
# config files never requires editing this number; it asserts that discovery
# worked, not that the tree has a particular size.
#
# Note what this floor can and cannot do. It is produced by ENUMERATION
# (git ls-files) and the verdict is produced by MATCHING (grep) — two different
# tools. THE FLOOR ASSERTS THAT DISCOVERY WORKED WHILE THE THING THAT CAN FAIL
# SILENTLY IS MATCHING. Enumeration succeeding tells you the denominator is
# real; it tells you nothing about whether anything was examined. The
# grep_status check above is what covers the other tool.
scanned=$(git ls-files \
  '*.yaml' '*.yml' '*.tf' '*.hcl' '*.tfvars' '*.json' 2>/dev/null | wc -l | tr -d ' ')
if [ "${scanned:-0}" -lt 100 ]; then
  echo "FAIL: only ${scanned:-0} scannable config file(s) found (expected >= 100)."
  echo "The scan could not see the tree, so it has nothing to report on and"
  echo "refuses to report a pass."
  exit 1
fi

if [ -n "$hits" ]; then
  echo "Unfilled placeholder sentinel(s) found in deploy config:"
  echo "$hits"
  echo
  echo "Deploy config must render from its source of truth, not carry a fill-me"
  echo "placeholder. If a path is a legitimate opt-in template, add it to the"
  echo "exclude list in scripts/no-placeholders.sh."
  exit 1
fi
echo "✓ no placeholder sentinels in deploy config (${scanned} config file(s) scanned)"
