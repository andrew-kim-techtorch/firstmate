#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# The lock file's second line stamps the holder's process identity (start time
# plus command, via fm_pid_identity) so a recycled pid - a new, unrelated
# process that reused the same pid and happens to match HARNESS_RE, e.g. a
# ChatGPT desktop app's "codex" helper - is not mistaken for the still-live
# original holder. An old lock written before this field existed has no second
# line and degrades to the prior pid+comm-only liveness check.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

harness_pid() {
  # Test-only seam: bypass the ancestry walk so a test harness (whose own
  # process tree does not run under claude/codex/etc) can exercise acquire and
  # status against a designated pid.
  if [ -n "${FM_LOCK_SELF_PID_OVERRIDE:-}" ]; then
    echo "$FM_LOCK_SELF_PID_OVERRIDE"
    return 0
  fi
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness AND,
                   # when $2 (a stamped identity) is given, still is that same
                   # process rather than an unrelated one that reused the pid
  local pid=$1 want_identity=${2:-} comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE" || return 1
  [ -n "$want_identity" ] || return 0
  [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$want_identity" ]
}

lock_pid() { sed -n '1p' "$LOCK" 2>/dev/null; }
lock_identity() { sed -n '2p' "$LOCK" 2>/dev/null; }

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(lock_pid)
  if holder_alive "$old" "$(lock_identity)"; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old dead, not a harness, or a recycled pid)"
  fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(lock_pid)
  if [ "$old" != "$me" ] && holder_alive "$old" "$(lock_identity)"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
{
  echo "$me"
  fm_pid_identity "$me" 2>/dev/null || true
} > "$LOCK"
echo "lock acquired: harness pid $me"
