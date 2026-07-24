#!/usr/bin/env bash
# Codex-specific submit verification for fm-send.
#
# During an active tool call Codex can acknowledge Enter by moving the steer to
# its visible follow-up queue while the queued row remains at the cursor.
# These tests keep that accepted state distinct from both a cleared composer and
# a genuinely swallowed Enter, and pin the exception to Codex targets only.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-codex-verification)

make_stubs() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
state="$FM_FAKE_STATE"
enters="$FM_FAKE_ENTERS"
case "${1:-}" in
  send-keys)
    case " $* " in
      *' -l '*) printf 'typed\n' > "$state" ;;
      *)
        printf 'enter\n' >> "$enters"
        case "$FM_FAKE_MODE" in
          landed) printf 'landed\n' > "$state" ;;
          queued) printf 'queued\n' > "$state" ;;
          failed) : ;;
        esac
        ;;
    esac
    exit 0
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in *cursor_y*) printf '0\n'; exit 0 ;; esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  capture-pane)
    current=$(cat "$state" 2>/dev/null || printf 'idle')
    case " $* " in
      *' -J '*)
        case "$FM_FAKE_MODE:$current" in
          queued:queued)
            printf 'Messages to be submitted after next tool call\n  ↳ fix verification\n'
            ;;
          stale-queue:*)
            printf 'Messages to be submitted after next tool call\n  ↳ older steer\n'
            ;;
          *) printf 'ordinary pane content\n' ;;
        esac
        ;;
      *)
        case "$current" in
          landed|idle) printf '│ > │\n' ;;
          typed|queued) printf '│ > fix verification │\n' ;;
        esac
        ;;
    esac
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

run_case() {  # <name> <harness> <mode> <expected-rc> <expected-enters>
  local name=$1 harness=$2 mode=$3 expected_rc=$4 expected_enters=$5
  local dir fb state enters rc actual_enters
  dir="$TMP_ROOT/$name"
  fb="$dir/fakebin"
  state="$dir/state"
  enters="$dir/enters"
  mkdir -p "$dir/home/state"
  make_stubs "$dir"
  printf 'idle\n' > "$state"
  : > "$enters"
  fm_write_meta "$dir/home/state/task.meta" "window=sess:win" "harness=$harness"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" \
    FM_FAKE_STATE="$state" FM_FAKE_ENTERS="$enters" FM_FAKE_MODE="$mode" \
    FM_SEND_SETTLE=0 "$SEND" fm-task 'fix verification' >/dev/null 2>&1
  rc=$?
  expect_code "$expected_rc" "$rc" "$name: unexpected fm-send exit code"
  actual_enters=$(wc -l < "$enters" | tr -d ' ')
  [ "$actual_enters" -eq "$expected_enters" ] \
    || fail "$name: expected $expected_enters Enter(s), got $actual_enters"
}

run_case landed codex landed 0 1
pass "fm-send Codex verification: a cleared composer is accepted as landed"

run_case queued codex queued 0 1
pass "fm-send Codex verification: a newly visible follow-up queue row is accepted without retry"

run_case genuine-failure codex failed 1 3
pass "fm-send Codex verification: unchanged queue plus pending text remains a failure"

run_case stale-queue-failure codex stale-queue 1 3
pass "fm-send Codex verification: a pre-existing unchanged queue does not mask failure"

run_case other-harness claude queued 1 3
pass "fm-send Codex verification: queue recognition does not weaken other harnesses"
