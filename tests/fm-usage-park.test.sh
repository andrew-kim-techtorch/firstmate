#!/usr/bin/env bash
# Behavior tests for bin/fm-usage-park.sh - the usage-blocked recovery helper.
#
# On a usage-blocked crew the recovery is park-don't-relaunch: a relaunch would
# inherit the same Claude account cap and discard the crew's loaded context +
# repro. fm-usage-park records the crew as parked and (re)writes ONE shared
# check.sh that fires once, when the reset time has passed, so a whole capped
# fleet surfaces the reopened window a single time instead of N times per sweep.
# These cases pin that contract hermetically over a throwaway state/ dir:
#   (a) park writes the parked-list, a numeric reset epoch, and an executable
#       shared check.sh
#   (b) the check.sh is silent before the reset, and fires + self-removes after
#   (c) multiple parks share ONE check and converge on the EARLIEST reset
#   (d) no reset time -> an estimated fallback epoch in the future
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PARK="$ROOT/bin/fm-usage-park.sh"
TMP_ROOT=$(fm_test_tmproot fm-usage-park)

new_state() {  # <name> -> echoes a fresh empty state dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d/state"
}

run_park() {  # <state> <id> [reset-clock]
  FM_STATE_OVERRIDE="$1" "$PARK" "$2" "${3:-}"
}

# (a) a single park writes all three artifacts, with a numeric future epoch.
test_park_writes_artifacts() {
  local state; state=$(new_state basic)
  local out; out=$(run_park "$state" fix-login-k3 "11:59pm")
  assert_contains "$out" "parked fix-login-k3" "reports the parked crew"
  assert_contains "$out" "do NOT relaunch" "warns against relaunch"
  assert_present "$state/.usage-parked" "parked-list file written"
  assert_present "$state/.usage-reset-epoch" "reset epoch file written"
  assert_present "$state/usage-retry.check.sh" "shared check.sh written"
  [ -x "$state/usage-retry.check.sh" ] || fail "check.sh must be executable"
  assert_grep "fix-login-k3" "$state/.usage-parked" "crew recorded in parked-list"
  local epoch; read -r epoch < "$state/.usage-reset-epoch"
  case "$epoch" in ''|*[!0-9]*) fail "reset epoch not numeric: '$epoch'" ;; esac
  [ "$epoch" -gt "$(date +%s)" ] || fail "11:59pm today should be a future epoch"
  pass "park writes parked-list, reset epoch, and an executable shared check.sh"
}

# (b) the check.sh stays silent before the reset, then fires ONCE and removes
# the epoch, parked-list, and itself.
test_check_fires_once_after_reset() {
  local state; state=$(new_state fires)
  run_park "$state" crew-a "11:59pm" >/dev/null
  local check="$state/usage-retry.check.sh"

  # Before reset (epoch is in the future): silent.
  local before; before=$("$check")
  [ -z "$before" ] || fail "check must be silent before the reset (got: '$before')"

  # Force the reset into the past, then it must fire and self-remove.
  printf '%s\n' "$(( $(date +%s) - 60 ))" > "$state/.usage-reset-epoch"
  local fired; fired=$("$check")
  assert_contains "$fired" "usage window reset reached" "fires after reset"
  assert_contains "$fired" "crew-a" "names the parked crew to re-nudge"
  assert_contains "$fired" "do NOT relaunch" "reiterates resume-in-place"
  assert_absent "$check" "check.sh self-removes after firing"
  assert_absent "$state/.usage-reset-epoch" "reset epoch cleared after firing"
  assert_absent "$state/.usage-parked" "parked-list cleared after firing"
  pass "shared check.sh fires exactly once after reset and cleans up"
}

# (c) two parks share ONE check and converge on the EARLIEST reset time.
test_multiple_parks_share_earliest_window() {
  local state; state=$(new_state shared)
  run_park "$state" crew-late "11:59pm" >/dev/null
  local late; read -r late < "$state/.usage-reset-epoch"
  # A second crew whose window reopens earlier must lower the shared epoch.
  run_park "$state" crew-early "12:01am" >/dev/null
  local shared; read -r shared < "$state/.usage-reset-epoch"
  [ "$shared" -le "$late" ] || fail "shared reset must be the earliest ($shared > $late)"
  local n; n=$(grep -c . "$state/.usage-parked")
  [ "$n" -eq 2 ] || fail "both crews should be parked ($n)"
  # Re-parking the same crew must not duplicate it.
  run_park "$state" crew-early "12:01am" >/dev/null
  n=$(grep -c . "$state/.usage-parked")
  [ "$n" -eq 2 ] || fail "re-parking a crew must be idempotent ($n)"
  local fired; printf '%s\n' "$(( $(date +%s) - 60 ))" > "$state/.usage-reset-epoch"
  fired=$("$state/usage-retry.check.sh")
  assert_contains "$fired" "crew-late" "shared check names every parked crew"
  assert_contains "$fired" "crew-early" "shared check names every parked crew"
  pass "multiple parks share one check on the earliest window, deduped"
}

# (d) with no reset time known, fall back to an estimated future epoch.
test_fallback_when_no_reset_time() {
  local state; state=$(new_state fallback)
  # No reset arg, and no live fm-crew-state to read one from -> fallback.
  local out; out=$(FM_USAGE_FALLBACK_SECS=3600 run_park "$state" crew-x "")
  assert_contains "$out" "ESTIMATED" "reports the reset was estimated"
  local epoch; read -r epoch < "$state/.usage-reset-epoch"
  case "$epoch" in ''|*[!0-9]*) fail "fallback epoch not numeric: '$epoch'" ;; esac
  local now; now=$(date +%s)
  [ "$epoch" -gt "$now" ] || fail "fallback epoch must be in the future"
  [ "$epoch" -le "$((now + 3700))" ] || fail "fallback epoch should be ~now+fallback"
  pass "no reset time falls back to an estimated future epoch"
}

test_park_writes_artifacts
test_check_fires_once_after_reset
test_multiple_parks_share_earliest_window
test_fallback_when_no_reset_time

echo "all fm-usage-park tests passed"
