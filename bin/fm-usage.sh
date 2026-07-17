#!/usr/bin/env bash
# fm-usage.sh - per-task/per-PR crew token+cost audit.
#
# Joins each live state/<id>.meta (worktree=, harness=, model=, pr=) against
# codeburn's per-project usage export. codeburn keys usage by "project" = the
# working-directory path a coding session ran in, which for a crewmate task is
# exactly its recorded worktree= path - that shared path is the whole bridge,
# so this never needs to touch a crewmate's own session transcripts directly.
#
# Torn-down tasks lose their meta file entirely (fm-teardown.sh removes it), so
# only currently in-flight state/*.meta tasks are covered - out of scope per
# the task brief unless codeburn is later asked to retain a path-keyed history
# independent of firstmate's own state.
#
# Usage: fm-usage.sh [--since YYYY-MM-DD]
#   --since  earliest date to include (default: 2020-01-01, i.e. all history)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  echo "usage: fm-usage.sh [--since YYYY-MM-DD]" >&2
}

SINCE="2020-01-01"
while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      [ $# -ge 2 ] || { usage; exit 1; }
      SINCE=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

command -v codeburn >/dev/null 2>&1 || { echo "fm-usage.sh: codeburn not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "fm-usage.sh: jq not found on PATH" >&2; exit 1; }

shopt -s nullglob
METAS=("$STATE"/*.meta)
shopt -u nullglob

if [ "${#METAS[@]}" -eq 0 ]; then
  echo "fm-usage.sh: no state/*.meta tasks found in $STATE" >&2
  exit 0
fi

# meta_get <file> <key>: last value of key=... in a meta file, or empty.
meta_get() {
  sed -n "s/^$2=//p" "$1" | tail -1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-usage.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

printf '%-28s %-8s %-16s %14s %10s  %s\n' "TASK" "HARNESS" "MODEL" "TOKENS" "COST" "PR"

for meta in "${METAS[@]}"; do
  id=$(basename "$meta" .meta)
  worktree=$(meta_get "$meta" worktree)
  harness=$(meta_get "$meta" harness)
  model=$(meta_get "$meta" model)
  pr=$(meta_get "$meta" pr)

  if [ -z "$worktree" ]; then
    echo "fm-usage.sh: $id: no worktree= in meta, skipping" >&2
    continue
  fi

  export_json="$TMP/$id.json"
  if ! codeburn export --format json --project "$worktree" --from "$SINCE" -o "$export_json" \
      >"$TMP/$id.out" 2>"$TMP/$id.err"; then
    echo "fm-usage.sh: $id: codeburn export failed: $(cat "$TMP/$id.err")" >&2
    continue
  fi

  # codeburn exits 0 and writes nothing when a project has no usage in range.
  if [ ! -s "$export_json" ]; then
    cost=0
    tokens=0
  else
    cost=0
    tokens=0
    if parsed=$(jq -r '
      (.projects[0]."Cost (USD)" // 0) as $cost |
      ([.periods[0].models[]? |
        (."Input Tokens" // 0) + (."Output Tokens" // 0)
        + (."Cache Read Tokens" // 0) + (."Cache Write Tokens" // 0)
      ] | add // 0) as $tok |
      "\($cost) \($tok)"
    ' "$export_json" 2>"$TMP/$id.jqerr"); then
      read -r cost tokens <<<"$parsed"
    else
      echo "fm-usage.sh: $id: usage parse failed: $(cat "$TMP/$id.jqerr")" >&2
    fi
  fi

  printf '%-28s %-8s %-16s %14s %10s  %s\n' \
    "$id" "${harness:--}" "${model:--}" "$tokens" "\$${cost}" "${pr:--}"
done
