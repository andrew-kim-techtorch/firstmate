#!/usr/bin/env bash
# Scan every project's no-mistakes gate hook for the buggy bare "$(pwd)"
# gate-path pattern (see fm-gate-hook-lib.sh) and repair it, unless
# --detect-only is passed. Called from fm-bootstrap.sh; also runnable
# standalone, and safe to run right after `no-mistakes init` or an upgrade.
# Usage: fm-gate-hook-check.sh [--detect-only] [projects-dir]
#   --detect-only  Report bad hooks without repairing them.
#   projects-dir   Directory of project clones to scan (default:
#                  $FM_PROJECTS_OVERRIDE or $FM_HOME/projects, matching
#                  fm-bootstrap.sh).
# Prints, per project with a bad hook, exactly one of:
#   "GATE_HOOK: <label>: needs repair (pwd -> /bin/pwd -P) at <hook-path>"
#   "GATE_HOOK: <label>: patched pwd -> /bin/pwd -P at <hook-path>"
#   "GATE_HOOK: <label>: patch failed at <hook-path>"
# Silent when no bad hooks are found. Always exits 0 so it never blocks
# bootstrap or the project-init flow.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-hook-lib.sh
. "$SCRIPT_DIR/fm-gate-hook-lib.sh"

detect_only=0
if [ "${1:-}" = "--detect-only" ]; then
  detect_only=1
  shift
fi

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${1:-${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}}"

[ -d "$PROJECTS" ] || exit 0

for proj in "$PROJECTS"/*; do
  [ -d "$proj" ] || continue
  label=$(basename "$proj")
  gate=$(gate_repo_for_project "$proj") || continue
  hook="$gate/hooks/post-receive"
  gate_hook_is_bad "$hook" || continue
  if [ "$detect_only" -eq 1 ]; then
    echo "GATE_HOOK: $label: needs repair (pwd -> /bin/pwd -P) at $hook"
  elif gate_hook_repair "$hook"; then
    echo "GATE_HOOK: $label: patched pwd -> /bin/pwd -P at $hook"
  else
    echo "GATE_HOOK: $label: patch failed at $hook"
  fi
done
exit 0
