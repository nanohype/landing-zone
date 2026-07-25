#!/usr/bin/env bash
#
# check-account-local-deps.sh — a workload environment must be installable from a
# standing start.
#
# The rule: no leaf under live/aws/workload-*/ may declare a `dependency` whose
# config_path resolves outside its own account directory. A cross-account dependency
# is legitimate (that is what adopt mode is), but not from a workload environment,
# because it makes that environment un-bringable-up on its own.
#
# Why this needs to be a check and not a convention. A terragrunt `dependency` is
# resolved while the unit's config is PARSED — before any tofu process starts, so no
# TF_VAR can bypass it and `init` fails just as hard as `apply`. But nothing in CI can
# see that:
#
#   - the evaluate job renders against mock_outputs by design, so a dependency with no
#     state resolves happily, and
#   - the plan job green-skips whenever AWS_ROLE_ARN is unset.
#
# So a leaf whose apply path cannot resolve stays green forever. That is exactly how a
# deliberate, well-reviewed change once made the default environment un-installable:
# the workload-development network leaf was pointed at a shared-network leaf in the
# network account, and every gate passed.
#
# Cross-account examples belong outside workload-*, where they can be rendered and read
# without claiming to be a deployable environment — see live/aws/reference-adopt/.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

while IFS= read -r leaf; do
  # live/aws/<account>/<region>/<env>/<component>/terragrunt.hcl
  account=$(printf '%s' "$leaf" | cut -d/ -f3)
  case "$account" in
    workload-*) ;;
    *) continue ;;
  esac

  leaf_dir=$(dirname "$leaf")
  account_dir="live/aws/$account"

  # Every config_path in the file, whether or not it is on a `dependency` line.
  while IFS= read -r cfg; do
    [ -n "$cfg" ] || continue

    # Resolve the path relative to the leaf, without requiring it to exist.
    resolved=$(cd "$leaf_dir" && printf '%s' "$(python3 - "$cfg" <<'PY'
import os, sys
print(os.path.normpath(os.path.join(os.getcwd(), sys.argv[1])))
PY
)")
    repo_root=$(pwd)
    rel=${resolved#"$repo_root"/}

    case "$rel" in
      "$account_dir"/*)
        ;;
      *)
        echo "::error file=$leaf::dependency config_path '$cfg' resolves to '$rel', outside $account_dir"
        echo "    A workload environment must install from a standing start. A dependency on"
        echo "    another account's state makes 'terragrunt init' fail before tofu runs, and no"
        echo "    TF_VAR can bypass it. Put cross-account worked examples under"
        echo "    live/aws/reference-adopt/ instead."
        fail=1
        ;;
    esac
  done < <(grep -oE 'config_path[[:space:]]*=[[:space:]]*"[^"]+"' "$leaf" | sed -E 's/.*"([^"]+)"/\1/')
done < <(git ls-files 'live/aws/workload-*/**/terragrunt.hcl')

if [ "$fail" -ne 0 ]; then
  echo
  echo "One or more workload leaves depend on state outside their own account."
  exit 1
fi

echo "All workload-* leaves depend only on units inside their own account directory."
