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
#   - every twelve-digit window of every run of twelve or more digits anywhere
#     in the raw value, keys and values alike, whether or not the value parses:
#     an id in an entry drift.yml rejects is still an id, and an id inside a
#     longer run is masked at whatever offset it starts.
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
#     line (`jq -c`). Its ids are masked before the refusal is printed.
#
# USAGE
#
#   mask-drift-role-map.sh              read DRIFT_PLAN_ROLE_ARNS from the
#                                       environment and print the masks
#   mask-drift-role-map.sh --self-test  run the built-in cases (synthetic ids
#                                       only) against this script itself;
#                                       ci.yml's workflows job runs it on every
#                                       pull request
#
# The self-test is what keeps this script honest. The script is the only thing
# keeping account ids out of drift.yml's public logs, and an edit that weakens
# it (a narrower id pattern, the multi-line refusal moved ahead of the id
# masks, a stray echo) would otherwise pass every other gate and first show
# itself as ids in a log. scripts/check-drift-workflow.py holds the other half:
# that drift.yml runs this as the first command of the first step, in each job,
# that receives the secret.
set -euo pipefail

self_test() {
  local script tmp failures=0 cases=0
  script="${BASH_SOURCE[0]}"
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: tmp is fixed for this run
  trap "rm -rf '$tmp'" RETURN

  # run_case NAME EXPECTED_EXIT MODE [VALUE]: MODE is "set" or "unset". Leaves
  # stdout in $tmp/out and stderr in $tmp/err for the expectations after it.
  run_case() {
    local name=$1 want=$2 mode=$3 value=${4-} got=0
    cases=$((cases + 1))
    if [ "$mode" = unset ]; then
      env -u DRIFT_PLAN_ROLE_ARNS bash "$script" >"$tmp/out" 2>"$tmp/err" || got=$?
    else
      DRIFT_PLAN_ROLE_ARNS="$value" bash "$script" >"$tmp/out" 2>"$tmp/err" || got=$?
    fi
    if [ "$got" -ne "$want" ]; then
      echo "FAIL [$name]: exit $got, want $want" >&2
      failures=$((failures + 1))
    fi
    if [ -s "$tmp/err" ]; then
      echo "FAIL [$name]: wrote to stderr" >&2
      failures=$((failures + 1))
    fi
    # Nothing but mask commands and error annotations, and no error annotation
    # carrying an id.
    if grep -vqE '^::(add-mask|error)::|^::error title=' "$tmp/out"; then
      echo "FAIL [$name]: printed a line that is neither ::add-mask:: nor ::error::" >&2
      failures=$((failures + 1))
    fi
    if grep -E '^::error' "$tmp/out" | grep -qE '[0-9]{12}'; then
      echo "FAIL [$name]: an ::error:: line carries a twelve-digit run" >&2
      failures=$((failures + 1))
    fi
  }
  expect_mask() {
    if ! grep -qxF "::add-mask::$2" "$tmp/out"; then
      echo "FAIL [$1]: no ::add-mask:: for a value that must be masked" >&2
      failures=$((failures + 1))
    fi
  }
  expect_no_mask_of() {
    if grep -qxF "::add-mask::$2" "$tmp/out"; then
      echo "FAIL [$1]: masked a value it must not register" >&2
      failures=$((failures + 1))
    fi
  }
  expect_count() {
    local got
    got=$(grep -cE "$2" "$tmp/out") || true
    if [ "$got" -ne "$3" ]; then
      echo "FAIL [$1]: $got line(s) matching $2, want $3" >&2
      failures=$((failures + 1))
    fi
  }

  local a1=arn:aws:iam::222233334444:role/github-actions-plan
  local a2=arn:aws:iam::555566667777:role/github-actions-plan

  run_case valid-map 0 set "{\"workload-staging\":\"$a1\",\"network\":\"$a2\"}"
  expect_mask valid-map 222233334444
  expect_mask valid-map 555566667777
  expect_mask valid-map "$a1"
  expect_mask valid-map "$a2"
  expect_count valid-map '^::error' 0
  expect_count valid-map '^::add-mask::' 4

  run_case trailing-newline 0 set "{\"backup\":\"$a1\"}"$'\n'
  expect_mask trailing-newline 222233334444
  expect_mask trailing-newline "$a1"
  expect_count trailing-newline '^::error' 0

  run_case id-as-key 0 set "{\"444455556666\":\"$a2\"}"
  expect_mask id-as-key 444455556666
  expect_mask id-as-key 555566667777
  expect_mask id-as-key "$a2"

  run_case not-json 0 set "not json 888877776666 at all"
  expect_mask not-json 888877776666
  expect_count not-json '^::add-mask::arn' 0
  expect_count not-json '^::error' 0

  run_case json-array 0 set "[\"$a1\"]"
  expect_mask json-array 222233334444
  expect_count json-array '^::error' 0

  run_case malformed-entries 0 set '{"backup":"arn:aws:iam::123412341234:user/someone","x":"999988887777","y":"arn:aws:iam::121212121212:role/p\nq"}'
  expect_mask malformed-entries 123412341234
  expect_mask malformed-entries 999988887777
  expect_mask malformed-entries 121212121212
  expect_no_mask_of malformed-entries 'arn:aws:iam::123412341234:user/someone'
  expect_count malformed-entries '^::add-mask::arn' 0

  # An id at any offset inside a longer digit run: every twelve-digit window.
  local long=314159265358979323846264 i
  run_case long-run 0 set "x${long}y"
  for ((i = 0; i + 12 <= ${#long}; i++)); do
    expect_mask long-run "${long:i:12}"
  done
  expect_count long-run '^::add-mask::' 13

  run_case unset 1 unset
  expect_count unset '^::error' 1
  expect_count unset '^::add-mask::' 0

  run_case empty 1 set ""
  expect_count empty '^::error' 1

  run_case whitespace-only 1 set $' \n\t '
  expect_count whitespace-only '^::error' 1

  # A multi-line value is refused, and its ids are masked BEFORE the refusal.
  run_case multi-line 1 set $'{\n  "network": "arn:aws:iam::313131313131:role/github-actions-plan"\n}'
  expect_mask multi-line 313131313131
  expect_count multi-line '^::error' 1
  if [ "$(head -n 1 "$tmp/out")" != "::add-mask::313131313131" ] ||
    [ "$(tail -n 1 "$tmp/out" | cut -c1-7)" != "::error" ]; then
    echo "FAIL [multi-line]: the id mask must come first and the refusal last" >&2
    failures=$((failures + 1))
  fi

  run_case carriage-return 1 set $'{"network":"arn:aws:iam::414141414141:role/p"}\r{"x":1}'
  expect_mask carriage-return 414141414141
  expect_count carriage-return '^::error' 1

  if [ "$failures" -ne 0 ]; then
    echo "mask-drift-role-map self-test FAILED: $failures assertion(s) over $cases case(s)" >&2
    return 1
  fi
  if [ "$cases" -lt 12 ]; then
    echo "mask-drift-role-map self-test ran only $cases case(s); refusing to report a pass" >&2
    return 1
  fi
  echo "mask-drift-role-map self-test passed ($cases cases)."
}

case "${1-}" in
  --self-test)
    self_test
    exit $?
    ;;
  "") ;;
  *)
    echo "::error::usage: mask-drift-role-map.sh [--self-test]"
    exit 2
    ;;
esac

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
# Every twelve-digit window of every run of twelve or more digits, so an id is
# masked wherever it starts inside a longer run.
ids=$(
  printf '%s' "$raw" | grep -oE '[0-9]{12,}' | while IFS= read -r run; do
    for ((i = 0; i + 12 <= ${#run}; i++)); do
      printf '%s\n' "${run:i:12}"
    done
  done | sort -u
) || true
if [ -n "$ids" ]; then
  while IFS= read -r id; do
    echo "::add-mask::${id}"
  done <<<"$ids"
fi

case "$raw" in
  *$'\n'* | *$'\r'*)
    echo "::error title=DRIFT_PLAN_ROLE_ARNS spans several lines::The runner masks each line of a multi-line secret separately, which would mask every brace in the log and drop the drift matrix as possibly secret. Store DRIFT_PLAN_ROLE_ARNS as single-line JSON (pipe it through jq -c; see docs/operations.md)."
    exit 1
    ;;
esac

# Then each role ARN, whole, when the value is a JSON object. A value that is
# not one is reported by the caller; its ids are already masked.
if printf '%s' "$raw" | jq -e 'type == "object"' >/dev/null 2>&1; then
  # The role-ARN shape drift.yml's select-accounts accepts, anchored at both
  # ends of the string (\A, \z) so a value carrying a line break is not one.
  arns=$(printf '%s' "$raw" | jq -r '.[] | strings | select(test("\\Aarn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+\\z"))' | sort -u)
  if [ -n "$arns" ]; then
    while IFS= read -r arn; do
      echo "::add-mask::${arn}"
    done <<<"$arns"
  fi
fi
