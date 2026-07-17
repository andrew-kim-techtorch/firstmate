#!/usr/bin/env bash
# fm-usage-park.sh - park a usage-blocked crew and schedule ONE shared auto-retry
# at the Claude usage-window reset, WITHOUT relaunching it.
#
# When fm-crew-state.sh reports a crew as `usage-blocked` (the Claude account cap,
# not a code failure), the right recovery is park-don't-relaunch: a relaunch
# inherits the same account cap and throws away the crew's loaded context + repro.
# This records the crew as parked and (re)writes a single shared check.sh that
# fires ONCE, when the reset time has passed, waking firstmate to re-nudge every
# parked crew to resume in place. One shared poll - not one per crew - so a whole
# capped fleet surfaces the reset a single time instead of N times per sweep.
#
# Reset time comes from the arg, else from fm-crew-state.sh's own detail. When no
# reset time is known, it falls back to now + FM_USAGE_FALLBACK_SECS (default 5h,
# the Claude window length) as an estimate. The clock is interpreted in
# America/Chicago (the captain's canonical TZ) unless the string carries its own
# "(<Area/City>)".
#
# Writes only firstmate's own state/ files (a sanctioned firstmate-machinery
# write, never a project). Idempotent: re-parking the same crew or lowering the
# shared reset is safe to repeat.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

FALLBACK_SECS=${FM_USAGE_FALLBACK_SECS:-18000}   # 5h: the Claude window length
case "$FALLBACK_SECS" in ''|*[!0-9]*) FALLBACK_SECS=18000 ;; esac

ID=${1:-}
RESET_CLOCK=${2:-}
[ -n "$ID" ] || { echo "usage: fm-usage-park.sh <id> [reset-clock]" >&2; exit 2; }

PARKED_FILE="$STATE/.usage-parked"
EPOCH_FILE="$STATE/.usage-reset-epoch"
CHECK_FILE="$STATE/usage-retry.check.sh"

# date -> epoch that works on both GNU (date -d) and BSD (date -j -f) date.
date_to_epoch() {  # <tz> <YYYY-MM-DD> <HH:MM>
  if date --version >/dev/null 2>&1; then
    TZ="$1" date -d "$2 $3" +%s 2>/dev/null
  else
    TZ="$1" date -j -f "%Y-%m-%d %H:%M" "$2 $3" +%s 2>/dev/null
  fi
}

# Parse a Claude reset-time string ("5:30pm", "7:20pm (America/Chicago)",
# "17:30") to an absolute epoch. Empty output + return 1 when unparseable.
parse_reset_to_epoch() {  # <reset-string>
  local s=$1 tz=America/Chicago tok hh mm ampm today ep now
  case "$s" in
    *\(*/*\)*) tz=$(printf '%s' "$s" | sed -n 's/.*(\([A-Za-z][A-Za-z]*\/[A-Za-z_][A-Za-z_]*\)).*/\1/p') ;;
  esac
  [ -n "$tz" ] || tz=America/Chicago
  tok=$(printf '%s' "$s" | grep -oiE '[0-9]{1,2}:[0-9]{2}[[:space:]]*([ap]m)?' | head -1)
  [ -n "$tok" ] || return 1
  hh=${tok%%:*}
  mm=${tok#*:}; mm=${mm%%[!0-9]*}
  case "$hh" in ''|*[!0-9]*) return 1 ;; esac
  case "$mm" in ''|*[!0-9]*) return 1 ;; esac
  ampm=$(printf '%s' "$tok" | grep -oiE '[ap]m' | head -1 | tr '[:upper:]' '[:lower:]')
  case "$ampm" in
    pm) [ "$hh" -lt 12 ] && hh=$((hh + 12)) ;;
    am) [ "$hh" -eq 12 ] && hh=0 ;;
  esac
  today=$(TZ="$tz" date +%Y-%m-%d) || return 1
  ep=$(date_to_epoch "$tz" "$today" "$(printf '%02d:%02d' "$hh" "$mm")") || return 1
  [ -n "$ep" ] || return 1
  # Cross-midnight: a clock that resolves to > 6h in the PAST must be tomorrow's
  # (the Claude window is <= 5h), so roll it forward one day.
  # ponytail: 6h threshold assumes the 5h window; widen if windows lengthen.
  now=$(date +%s)
  [ "$ep" -lt "$((now - 21600))" ] && ep=$((ep + 86400))
  printf '%s' "$ep"
}

mkdir -p "$STATE"

# Resolve the reset clock: explicit arg wins, else read fm-crew-state's detail.
if [ -z "$RESET_CLOCK" ]; then
  state_line=$("$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null || true)
  RESET_CLOCK=$(printf '%s' "$state_line" | sed -n 's/.*resets[[:space:]][[:space:]]*//p' | head -1)
fi

ESTIMATED=0
EPOCH=""
[ -n "$RESET_CLOCK" ] && EPOCH=$(parse_reset_to_epoch "$RESET_CLOCK")
if [ -z "$EPOCH" ]; then
  EPOCH=$(( $(date +%s) + FALLBACK_SECS ))
  ESTIMATED=1
fi

# Record this crew as parked (dedup).
touch "$PARKED_FILE"
grep -qxF "$ID" "$PARKED_FILE" 2>/dev/null || printf '%s\n' "$ID" >> "$PARKED_FILE"

# The shared reset is the EARLIEST across all parked crews, so the retry fires as
# soon as the first window reopens.
if [ -f "$EPOCH_FILE" ]; then
  read -r prev < "$EPOCH_FILE" 2>/dev/null || prev=""
  case "$prev" in
    ''|*[!0-9]*) : ;;
    *) [ "$prev" -lt "$EPOCH" ] && EPOCH=$prev ;;
  esac
fi
printf '%s\n' "$EPOCH" > "$EPOCH_FILE"

# (Re)write the single shared auto-retry poll. It reads the epoch/parked files at
# fire time (so a later re-park can lower the reset without a rewrite) and
# self-removes after firing, so the reset surfaces exactly once.
cat > "$CHECK_FILE" <<'SH'
#!/usr/bin/env bash
# Shared usage-limit auto-retry poll (written by bin/fm-usage-park.sh). Fires
# ONCE when the Claude usage window reset has passed, waking firstmate to
# re-nudge every PARKED usage-blocked crew to resume WITHOUT relaunching
# (park-don't-relaunch preserves each crew's loaded context + repro). Prints
# nothing until then; self-removes after firing so the reset surfaces once, not
# once per crew per sweep.
set -u
dir=$(cd "$(dirname "$0")" && pwd)
epoch_file="$dir/.usage-reset-epoch"
parked_file="$dir/.usage-parked"
[ -f "$epoch_file" ] || exit 0
read -r epoch < "$epoch_file" 2>/dev/null || exit 0
case "$epoch" in ''|*[!0-9]*) exit 0 ;; esac
[ "$(date +%s)" -ge "$epoch" ] || exit 0
crews=$(tr '\n' ' ' < "$parked_file" 2>/dev/null)
echo "Claude usage window reset reached - re-nudge parked crew(s) to resume in place (do NOT relaunch): ${crews:-none}"
rm -f -- "$epoch_file" "$parked_file" "$0"
SH
chmod +x "$CHECK_FILE"

# Human-readable retry time for the operator summary.
if date --version >/dev/null 2>&1; then
  human=$(TZ=America/Chicago date -d "@$EPOCH" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)
else
  human=$(TZ=America/Chicago date -r "$EPOCH" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)
fi
parked_list=$(tr '\n' ' ' < "$PARKED_FILE" 2>/dev/null)

printf 'parked %s (do NOT relaunch - would inherit the same account cap)\n' "$ID"
if [ "$ESTIMATED" = 1 ]; then
  printf 'auto-retry armed for ~%s (ESTIMATED: no reset time was shown; +%ss fallback)\n' "${human:-epoch $EPOCH}" "$FALLBACK_SECS"
else
  printf 'auto-retry armed for %s (from "%s")\n' "${human:-epoch $EPOCH}" "$RESET_CLOCK"
fi
printf 'parked crews sharing this window: %s\n' "${parked_list:-none}"
printf 'active Claude usage window recorded at %s - hold new Claude dispatches until it passes\n' "$EPOCH_FILE"
