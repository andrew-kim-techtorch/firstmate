#!/usr/bin/env bash
# Behavior tests for the no-mistakes gate-hook self-heal.
#
# no-mistakes' generated post-receive hook used a bare "$(pwd)" to resolve its
# own gate directory. Pushing from a linked git worktree (every crewmate ship
# task) leaves $PWD as "." during receive-pack, so the daemon rejects the push
# with "invalid gate path: ." and no validation run is ever created. The fix
# is "$(pwd)" -> "$(pwd -P)" (see bin/fm-gate-hook-lib.sh). These cases pin the
# lib's detect/repair primitives and the fm-gate-hook-check.sh CLI that scans
# every project and either reports or repairs, hermetic over fixture hooks and
# fake project/gate-repo pairs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-gate-hook-lib.sh
. "$ROOT/bin/fm-gate-hook-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-gate-hook)
fm_git_identity fmtest fmtest@example.invalid

# The exact buggy shape no-mistakes generates: bare "$(pwd)" for both --gate
# and the log path.
# shellcheck disable=SC2016  # single quotes are intentional: this is fixture text, not code to run here
BAD_HOOK='#!/bin/sh
NM_BIN=no-mistakes
LOG="$(pwd)/notify-push.log"
while read oldrev newrev refname; do
  set -- --gate "$(pwd)" --ref "$refname" --old "$oldrev" --new "$newrev"
  "$NM_BIN" daemon notify-push "$@"
done
exit 0
'

write_bad_hook() {
  local dir=$1
  mkdir -p "$dir"
  printf '%s' "$BAD_HOOK" > "$dir/post-receive"
  chmod +x "$dir/post-receive"
  printf '%s\n' "$dir/post-receive"
}

# --- lib: gate_hook_is_bad ---------------------------------------------------

test_is_bad_detection() {
  local dir hook
  dir="$TMP_ROOT/lib-detect"
  hook=$(write_bad_hook "$dir")

  gate_hook_is_bad "$hook" || fail "bad hook was not detected as bad"

  gate_hook_repair "$hook" || fail "repair failed"
  gate_hook_is_bad "$hook" && fail "patched hook still reported as bad"

  gate_hook_is_bad "$TMP_ROOT/lib-detect/no-such-hook" && fail "missing hook wrongly reported as bad"
  pass "gate_hook_is_bad: flags the bare \$(pwd) pattern and clears after repair"
}

# --- lib: gate_hook_repair ---------------------------------------------------

test_repair_rewrite_and_idempotence() {
  local dir hook content
  dir="$TMP_ROOT/lib-repair"
  hook=$(write_bad_hook "$dir")

  gate_hook_repair "$hook" || fail "first repair failed"
  content=$(cat "$hook")
  # shellcheck disable=SC2016  # single quotes are intentional: literal strings, no shell expansion
  assert_contains "$content" '--gate "$(pwd -P)"' "repair did not patch the --gate argument"
  # shellcheck disable=SC2016  # single quotes are intentional: literal strings, no shell expansion
  assert_contains "$content" 'LOG="$(pwd -P)/notify-push.log"' "repair did not patch the LOG assignment"
  # shellcheck disable=SC2016  # single quotes are intentional: literal strings, no shell expansion
  assert_not_contains "$content" '$(pwd)' "repair left a bare \$(pwd) behind"

  # Idempotent: a second repair on an already-good hook changes nothing and
  # still succeeds.
  gate_hook_repair "$hook" || fail "second repair on an already-good hook failed"
  [ "$(cat "$hook")" = "$content" ] || fail "second repair changed an already-good hook"
  pass "gate_hook_repair: rewrites every bare \$(pwd) to \$(pwd -P) and is idempotent"

  # Executable bit and permissions survive the tmp-file-then-mv repair.
  [ -x "$hook" ] || fail "repair dropped the hook's executable bit"
}

# --- lib: gate_repo_for_project ----------------------------------------------

make_project_with_gate() {
  local proj=$1 gate=$2
  git init -q "$proj"
  git -C "$proj" commit -q --allow-empty -m init
  mkdir -p "$gate/hooks"
  git -C "$proj" remote add no-mistakes "$gate"
}

test_gate_repo_for_project() {
  local proj gate out
  proj="$TMP_ROOT/proj-with-gate"
  gate="$TMP_ROOT/gate-repo"
  make_project_with_gate "$proj" "$gate"

  out=$(gate_repo_for_project "$proj") || fail "gate_repo_for_project failed to resolve a configured remote"
  [ "$out" = "$gate" ] || fail "gate_repo_for_project resolved '$out', expected '$gate'"

  git init -q "$TMP_ROOT/proj-no-gate"
  gate_repo_for_project "$TMP_ROOT/proj-no-gate" >/dev/null 2>&1 && fail "gate_repo_for_project wrongly resolved a project with no no-mistakes remote"
  pass "gate_repo_for_project: resolves the no-mistakes remote path, or nothing when absent"
}

# --- CLI: fm-gate-hook-check.sh ----------------------------------------------

run_check() {
  local projects=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ROOT" FM_PROJECTS_OVERRIDE="$projects" \
    "$ROOT/bin/fm-gate-hook-check.sh" "$@" 2>&1
}

test_cli_detect_only_does_not_write() {
  local projects proj gate hook out before after
  projects="$TMP_ROOT/cli-detect-projects"
  mkdir -p "$projects"
  proj="$projects/alpha"
  gate="$TMP_ROOT/cli-detect-gate"
  make_project_with_gate "$proj" "$gate"
  hook=$(write_bad_hook "$gate/hooks")
  before=$(cat "$hook")

  out=$(run_check "$projects" --detect-only)
  assert_contains "$out" "GATE_HOOK: alpha: needs repair (pwd -> pwd -P) at $hook" "detect-only did not report the bad hook"
  after=$(cat "$hook")
  [ "$before" = "$after" ] || fail "detect-only mode modified the hook file"
  pass "fm-gate-hook-check.sh --detect-only: reports a bad hook without repairing it"
}

test_cli_repairs_and_then_is_silent() {
  local projects proj gate hook out
  projects="$TMP_ROOT/cli-repair-projects"
  mkdir -p "$projects"
  proj="$projects/beta"
  gate="$TMP_ROOT/cli-repair-gate"
  make_project_with_gate "$proj" "$gate"
  hook=$(write_bad_hook "$gate/hooks")

  out=$(run_check "$projects")
  assert_contains "$out" "GATE_HOOK: beta: patched pwd -> pwd -P at $hook" "repair mode did not report the patch"
  # shellcheck disable=SC2016  # single quotes are intentional: literal string, no shell expansion
  assert_not_contains "$(cat "$hook")" '$(pwd)' "repair mode left a bare \$(pwd) behind"

  out=$(run_check "$projects")
  [ -z "$out" ] || fail "repeat run over an already-patched hook was not silent: $out"
  pass "fm-gate-hook-check.sh: repairs a bad hook, then stays silent on a clean rerun"
}

test_cli_ignores_healthy_projects() {
  local projects proj gate out
  projects="$TMP_ROOT/cli-healthy-projects"
  mkdir -p "$projects"
  proj="$projects/gamma"
  gate="$TMP_ROOT/cli-healthy-gate"
  make_project_with_gate "$proj" "$gate"
  printf '#!/bin/sh\nexit 0\n' > "$gate/hooks/post-receive"
  chmod +x "$gate/hooks/post-receive"

  out=$(run_check "$projects")
  [ -z "$out" ] || fail "a project with no bad pattern was reported: $out"

  out=$(run_check "$TMP_ROOT/no-such-projects-dir")
  [ -z "$out" ] || fail "a missing projects dir was reported: $out"
  pass "fm-gate-hook-check.sh: silent for a healthy hook and a missing projects dir"
}

test_is_bad_detection
test_repair_rewrite_and_idempotence
test_gate_repo_for_project
test_cli_detect_only_does_not_write
test_cli_repairs_and_then_is_silent
test_cli_ignores_healthy_projects
