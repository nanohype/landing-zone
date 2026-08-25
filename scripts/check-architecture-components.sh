#!/usr/bin/env bash
#
# The component tables in docs/architecture.md must name exactly the components
# that exist.
#
# Both directions matter and they fail differently. A documented component that
# is not in the tree sends a reader to a directory that is not there — the shape
# this gate was written for, after the per-app substrate components were deleted
# and their table row was not. A component in the tree that no table names is
# quieter and worse: the doc reads as a complete inventory, so the omission is
# invisible to anyone who has not already listed the directory themselves.
#
# Scope is the `## Layer Breakdown` section, which is where components are
# enumerated. The teams table further down bolds team names in the same column
# position, so reading the whole file would demand that `sre` and `finops` be
# components — a gate that fails on correct content, which gets relaxed until it
# accepts everything.
#
# Names come from `git ls-files`, so an untracked leftover under components/aws/
# (a local `.terraform/` cache, say) is not mistaken for a component.
set -euo pipefail

cd "$(dirname "$0")/.."

DOC="docs/architecture.md"
[ -f "$DOC" ] || { echo "FAIL: $DOC is missing"; exit 1; }

# Two ways a layer names its components, both load-bearing: a table row for the
# layers that hold several, and a `**Component:** `name`` line for the layers
# written as prose. Reading only the tables would demand a row for `network`,
# which has a whole section of its own — a gate failing on correct content.
layer_section=$(awk '/^## Layer Breakdown/{inside=1; next} /^## /{inside=0} inside' "$DOC")

documented=$(
  {
    echo "$layer_section" | grep -oE '^\| \*\*[a-z0-9-]+\*\*' | sed 's/^| \*\*//; s/\*\*$//'
    echo "$layer_section" | grep -E '^\*\*Component:\*\*' | grep -oE '`[a-z0-9-]+`' | tr -d '`'
  } | sort -u
)
actual=$(git ls-files components/aws/ | cut -d/ -f3 | sort -u)

# A pattern that matched nothing would make every comparison below vacuously
# pass, and the tables are never empty.
if [ -z "$documented" ]; then
  echo "FAIL: no component names parsed out of $DOC — the table format changed and this gate is now blind"
  exit 1
fi

missing_from_tree=$(comm -23 <(echo "$documented") <(echo "$actual"))
missing_from_doc=$(comm -13 <(echo "$documented") <(echo "$actual"))

status=0
if [ -n "$missing_from_tree" ]; then
  echo "FAIL: $DOC documents components that do not exist under components/aws/:"
  echo "$missing_from_tree" | sed 's/^/  - /'
  status=1
fi
if [ -n "$missing_from_doc" ]; then
  echo "FAIL: components/aws/ holds components no table in $DOC names:"
  echo "$missing_from_doc" | sed 's/^/  - /'
  status=1
fi

# CLAUDE.md carries a second inventory — the layer-grouped component list loaded
# into every session in this repo — and it drifted six components behind the tree
# while docs/architecture.md stayed exact, because only one of the two was gated.
#
# Only the omission direction is checked here, and only by name. CLAUDE.md is
# prose, not a table: demanding a parseable shape would fix its formatting in
# place, and the opposite direction (naming a component that is gone) already
# fails visibly for a reader, whereas a missing one reads as a complete list.
CLAUDE_DOC="CLAUDE.md"
if [ -f "$CLAUDE_DOC" ]; then
  unnamed=""
  while IFS= read -r c; do
    grep -qF -- "\`$c\`" "$CLAUDE_DOC" || unnamed="$unnamed$c"$'\n'
  done <<<"$actual"
  if [ -n "$unnamed" ]; then
    echo "FAIL: components/aws/ holds components $CLAUDE_DOC never names:"
    printf '%s' "$unnamed" | sed 's/^/  - /'
    echo "  ($CLAUDE_DOC presents a grouped inventory, so an omission reads as 'this component does not exist')"
    status=1
  fi
fi

[ "$status" -eq 0 ] && echo "PASS: $DOC names exactly the $(echo "$actual" | wc -l | tr -d ' ') components in the tree, and $CLAUDE_DOC names every one"
exit "$status"
