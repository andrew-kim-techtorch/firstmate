#!/usr/bin/env bash
# Record a PR-ready task: appends pr=<url> and GitHub's pr_head=<sha> to
# state/<id>.meta when available, then arms the watcher's merge poll by writing
# state/<id>.check.sh, which prints one line iff the PR is merged (the watcher's
# check contract: output = wake firstmate, silence = keep sleeping).
# First it runs the canonical PR-body substance gate (fm-pr-body-check.sh) so a
# bare or pipeline-default body cannot be relayed as ready; that gate is the
# one-owner of the standard and this script does not restate it. The core
# non---ui check runs here because fm-pr-check does not know if a change is
# UI-visible; --ui stays firstmate's explicit per-task call per AGENTS.md 7.
# A local-filesystem-path failure (the recurring no-mistakes-evidence-step
# case; see fm-pr-body-sanitize.sh) is auto-sanitized and the gate retried once
# before failing; every other substance failure still fails immediately.
# The body gate is the relay path's; fm-pr-merge.sh's merge-recording call sets
# FM_PR_CHECK_SKIP_BODY_GATE=1 because a captain-approved or yolo merge already
# cleared the relay gate, and re-checking at merge time would block on a
# transient gh failure or a body edited after PR-ready, beyond this gate's scope.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=$1
URL=$2

# Relay-path body gate: fail loudly before recording pr= or arming the poll.
# fm-pr-body-check.sh prints its own one-line reason to stderr and exits non-zero.
# A failure naming a local filesystem path is self-healing: the no-mistakes
# pipeline's own evidence step is the recurring source of those paths (see
# bin/fm-pr-body-sanitize.sh's header), so run the sanitizer once and retry the
# gate instead of forcing a manual rewrite for this one known-recoverable case.
# Any other substance failure (missing sections, bare body, bad mermaid, ...)
# still fails immediately, unchanged.
if [ "${FM_PR_CHECK_SKIP_BODY_GATE:-0}" != 1 ]; then
  if ! BODY_CHECK_ERR=$("$FM_ROOT/bin/fm-pr-body-check.sh" "$URL" 2>&1); then
    printf '%s\n' "$BODY_CHECK_ERR" >&2
    if printf '%s' "$BODY_CHECK_ERR" | grep -q 'local filesystem path'; then
      echo "fm-pr-check: PR body has local evidence paths; auto-sanitizing and retrying" >&2
      if ! "$FM_ROOT/bin/fm-pr-body-sanitize.sh" "$URL" >&2; then
        echo "fm-pr-check: auto-sanitize failed; rewrite the PR body before relaying $URL" >&2
        exit 1
      fi
      if ! "$FM_ROOT/bin/fm-pr-body-check.sh" "$URL"; then
        echo "fm-pr-check: PR body still fails the canonical substance gate after auto-sanitize (above); rewrite it before relaying $URL" >&2
        exit 1
      fi
    else
      echo "fm-pr-check: PR body failed the canonical substance gate (above); rewrite it before relaying $URL" >&2
      exit 1
    fi
  fi
fi

META="$STATE/$ID.meta"
if [ -f "$META" ]; then
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
  PR_HEAD=
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    if command -v gh >/dev/null 2>&1; then
      if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null); then
        PR_HEAD=$REMOTE_HEAD
      fi
    fi
  fi
  if ! grep -qxF "pr=$URL" "$META"; then
    echo "pr=$URL" >> "$META"
  fi
  if [ -n "$PR_HEAD" ] && ! grep -qxF "pr_head=$PR_HEAD" "$META"; then
    echo "pr_head=$PR_HEAD" >> "$META"
  fi
fi

cat > "$STATE/$ID.check.sh" <<EOF
state=\$(gh pr view "$URL" --json state -q .state 2>/dev/null)
[ "\$state" = "MERGED" ] && echo "merged"
EOF
echo "armed: state/$ID.check.sh polls $URL"
