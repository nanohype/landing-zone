# Owner-side contract assertion. A participant account cannot see, from its own side, whether
# the Profile it associates actually carries any consumers or zones — it only sees the
# association succeed. So the owner asserts here, where it is observable, that the share has
# consumers. The README documents the same contract in prose for anyone hand-rolling a
# non-terraform owner against it.
#
# check blocks surface a breach as a plan/apply warning (non-blocking by design); the tofu
# test suite gates it hard via expect_failures, so a regression that forgets the consumers
# fails CI, not just the next apply's log. Zone-count is enforced as a hard variable validation
# (an empty Profile is never valid), so it does not need a soft check here.

check "consumers_declared" {
  assert {
    condition     = length(var.consumer_account_ids) > 0
    error_message = "consumer_account_ids is empty — a shared-dns Profile with no consumers is shared to nobody. Declare the workload account(s) that adopt this Profile, or this is an orphan share."
  }
}
