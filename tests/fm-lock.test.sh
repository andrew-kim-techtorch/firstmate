#!/usr/bin/env bash
# tests/fm-lock.test.sh - fm-lock.sh recycled-pid hardening. A stale session
# lock naming a pid that has since been reused by an unrelated
# harness-named process (e.g. a ChatGPT desktop app's "codex" helper) must not
# read as a live firstmate session forever; the stamped process identity
# (start time + command) is what tells the two apart.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LOCK="$ROOT/bin/fm-lock.sh"
LIB="$ROOT/bin/fm-wake-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-lock-tests)

# make_ps_fake <fakebin> <fake_pid>: install a ps shim that reports comm/args
# matching HARNESS_RE for <fake_pid> only, passing every other query (and every
# other field, e.g. lstart/command for identity) straight to the real ps. This
# lets a genuinely live background process (real pid, real start time) stand in
# for "a harness-named process holds this pid" without needing a real
# claude/codex/etc binary on PATH.
make_ps_fake() {
  local fakebin=$1 fake_pid=$2 real_ps
  real_ps=$(command -v ps)
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
set -u
REAL_PS="$real_ps"
FAKE_PID="$fake_pid"
SH
  cat >> "$fakebin/ps" <<'SH'
pid=""
field=""
prev=""
for a in "$@"; do
  case "$prev" in -p) pid="$a" ;; esac
  case "$a" in -o) : ;; -ocomm=|comm=) field=comm ;; args=) field=args ;; esac
  prev="$a"
done
if [ "$pid" = "$FAKE_PID" ]; then
  case "$field" in
    comm) printf 'codex\n'; exit 0 ;;
    args) printf 'codex --fake\n'; exit 0 ;;
  esac
fi
exec "$REAL_PS" "$@"
SH
  chmod +x "$fakebin/ps"
}

test_recycled_pid_is_not_the_lock_owner() {
  local dir state fakebin live identity_real
  dir=$(make_case recycled-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sleep 300 &
  live=$!
  make_ps_fake "$fakebin" "$live"
  identity_real=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live")
  [ -n "$identity_real" ] || fail "could not compute identity for the live stand-in process"
  {
    echo "$live"
    echo "stale identity from a different, since-exited holder"
  } > "$state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_LOCK_SELF_PID_OVERRIDE=1 "$LOCK" 2>&1)
  rc=$?
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "acquire refused despite a stamped-identity mismatch (recycled pid): $out"
  grep -qF 'lock acquired' <<<"$out" || fail "acquire did not report success over a recycled pid: $out"
  pass "a live process reusing a stale lock's pid+comm is not treated as the lock owner"
}

test_genuinely_live_session_still_holds_lock() {
  local dir state fakebin live identity
  dir=$(make_case genuinely-live)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sleep 300 &
  live=$!
  make_ps_fake "$fakebin" "$live"
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$LIB" "$live")
  [ -n "$identity" ] || fail "could not compute identity for the live stand-in process"
  {
    echo "$live"
    printf '%s\n' "$identity"
  } > "$state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_LOCK_SELF_PID_OVERRIDE=1 "$LOCK" 2>&1)
  rc=$?
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "acquire succeeded despite a genuinely live, identity-matched holder: $out"
  grep -qF 'another live firstmate session holds the lock' <<<"$out" || fail "acquire did not report the live holder: $out"
  pass "a genuinely live session (matching pid+comm+identity) still holds its lock"
}

test_dead_pid_lock_is_stale() {
  local dir state fakebin dp out
  dir=$(make_case dead-pid)
  state="$dir/state"
  fakebin="$dir/fakebin"
  dp=$(dead_pid)
  {
    echo "$dp"
    echo "whatever identity, the pid itself is dead"
  } > "$state/.lock"
  out=$(FM_STATE_OVERRIDE="$state" FM_LOCK_SELF_PID_OVERRIDE=1 "$LOCK" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "acquire refused over a lock naming a dead pid: $out"
  grep -qF 'lock acquired' <<<"$out" || fail "acquire did not report success over a dead-pid lock: $out"
  pass "a lock naming a dead pid is stale and breakable"
}

test_old_format_lock_with_no_identity_degrades() {
  local dir state fakebin live out
  dir=$(make_case old-format)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sleep 300 &
  live=$!
  make_ps_fake "$fakebin" "$live"
  printf '%s\n' "$live" > "$state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_LOCK_SELF_PID_OVERRIDE=1 "$LOCK" 2>&1)
  rc=$?
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  [ "$rc" -ne 0 ] || fail "acquire succeeded over a live pid+comm match despite an old single-line lock: $out"
  grep -qF 'another live firstmate session holds the lock' <<<"$out" || fail "old-format lock did not degrade to pid+comm liveness: $out"
  pass "an old single-line lock (no stamped identity) degrades to pid+comm liveness"
}

test_status_reports_recycled_pid_as_stale() {
  local dir state fakebin live out
  dir=$(make_case status-recycled)
  state="$dir/state"
  fakebin="$dir/fakebin"
  sleep 300 &
  live=$!
  make_ps_fake "$fakebin" "$live"
  {
    echo "$live"
    echo "stale identity from a different, since-exited holder"
  } > "$state/.lock"
  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$LOCK" status 2>&1)
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true
  grep -qF 'lock: stale' <<<"$out" || fail "status did not report a recycled-pid lock as stale: $out"
  pass "status reports a recycled-pid lock as stale"
}

test_recycled_pid_is_not_the_lock_owner
test_genuinely_live_session_still_holds_lock
test_dead_pid_lock_is_stale
test_old_format_lock_with_no_identity_degrades
test_status_reports_recycled_pid_as_stale
