#!/usr/bin/env bash
# Registers every account id and role ARN in DRIFT_PLAN_ROLE_ARNS with the
# GitHub Actions runner's log masker, before anything else in the job prints.
#
# WHY THIS EXISTS
#
# drift.yml reads DRIFT_PLAN_ROLE_ARNS, a secret on the `drift` GitHub
# Environment: a JSON object mapping each account directory under live/aws/ to
# the read-only plan role github-oidc creates in that account. The repository is
# public, and every value carries a real account id.
#
# The runner masks a secret as a whole, so the env block a step prints shows
# `***` for the secret itself. It does not mask a PART of one: a single role ARN
# taken out of the map, the account id inside it, or a plan error naming the
# state bucket `<account_id>-<region>-tfstate` would be printed in the clear. So
# each job that reads the secret runs this as the first thing in the first step
# that receives it, and every id and ARN is masked from that line on, for the
# rest of the job: later output in this step, and every later step's env block,
# action inputs and output. Masks are per job, so each job runs it.
#
# WHAT IT MASKS
#
#   - every run of twelve digits anywhere in the raw value (a longer run as
#     consecutive twelve-digit chunks), keys and values alike, whether or not
#     the value parses: an id in an entry drift.yml rejects is still an id.
#   - every value that is an IAM role ARN, whole, when the value is a JSON
#     object.
#
# It prints nothing but `::add-mask::` commands and, on refusal, an `::error::`
# that names no part of the value.
#
# WHAT IT REFUSES (exit 1)
#
#   - an unset or empty value. drift.yml cannot plan anything without it.
#   - a value spanning more than one line, after leading and trailing
#     whitespace is trimmed. The runner masks each line of a multi-line secret
#     on its own, so a pretty-printed map would register `{` and `}` as secrets:
#     every brace in the log turns to `***`, and select-accounts' matrix output,
#     which is JSON, would be dropped as "may contain secret". Store it as one
#     line (`jq -c`).
#
# Reads DRIFT_PLAN_ROLE_ARNS from the environment; takes no arguments.
set -euo pipefail

raw="${DRIFT_PLAN_ROLE_ARNS:-}"
# Trim leading and trailing whitespace (a trailing newline from `gh secret set`
# reading a file is not a second line).
raw="${raw#"${raw%%[![:space:]]*}"}"
raw="${raw%"${raw##*[![:space:]]}"}"

if [ -z "$raw" ]; then
  echo "::error title=DRIFT_PLAN_ROLE_ARNS is not set::Drift detection cannot run: the drift GitHub Environment has no DRIFT_PLAN_ROLE_ARNS secret (Settings > Environments > drift > Environment secrets), so no account has a plan role and no drift was checked. Set it to a single-line JSON object mapping each account directory under live/aws/ to the plan role github-oidc creates in that account (see docs/operations.md)."
  exit 1
fi

# Ids first: this needs no parse, so it holds for a value that is not JSON.
ids=$(printf '%s' "$raw" | grep -oE '[0-9]{12}' | sort -u) || true
if [ -n "$ids" ]; then
  while IFS= read -r id; do
    echo "::add-mask::${id}"
  done <<EOF
$ids
EOF
fi

case "$raw" in
  *$'\n'* | *$'\r'*)
    echo "::error title=DRIFT_PLAN_ROLE_ARNS spans several lines::The runner masks each line of a multi-line secret separately, which would mask every brace in the log and drop the drift matrix as possibly secret. Store DRIFT_PLAN_ROLE_ARNS as single-line JSON (pipe it through jq -c; see docs/operations.md)."
    exit 1
    ;;
esac

# Then each role ARN, whole, when the value is a JSON object. A value that is
# not one is reported by the caller; its ids are already masked.
if printf '%s' "$raw" | jq -e 'type == "object"' > /dev/null 2>&1; then
  # The role-ARN shape drift.yml's select-accounts accepts, anchored at both
  # ends of the string (\A, \z) so a value carrying a line break is not one.
  arns=$(printf '%s' "$raw" | jq -r '.[] | strings | select(test("\\Aarn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+\\z"))' | sort -u)
  if [ -n "$arns" ]; then
    while IFS= read -r arn; do
      echo "::add-mask::${arn}"
    done <<EOF
$arns
EOF
  fi
fi
