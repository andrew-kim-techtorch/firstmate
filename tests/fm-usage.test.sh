#!/usr/bin/env bash
# Behavior tests for bin/fm-usage.sh - the per-task crew token+cost audit.
#
# The bridge under test is: state/<id>.meta's worktree= is exactly the
# "project" key codeburn uses to key usage, so fm-usage.sh joins the two by
# calling `codeburn export --format json --project <worktree> ...` once per
# task. These tests fake codeburn with a stub that returns canned per-project
# JSON keyed by the worktree it was asked for, so no real codeburn install or
# usage history is needed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE="$ROOT/bin/fm-usage.sh"

test_script_parses() {
  bash -n "$USAGE" 2>&1 || fail "bin/fm-usage.sh fails bash -n"
  pass "fm-usage.sh: bash -n succeeds"
}

# A fake codeburn: reads --project/-o off argv and writes canned JSON matching
# the real CLI's export --json shape (a "projects" summary array plus a single
# custom-range "periods" entry carrying per-model token breakdown). A project
# with no usage matches the real CLI's own behavior for an empty range: it
# prints a message and writes nothing, exit 0.
make_fake_codeburn() {
  local fakebin=$1
  cat > "$fakebin/codeburn" <<'SH'
#!/usr/bin/env bash
set -eu
project="" out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) project=$2; shift 2 ;;
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$project" in
  */wt-alpha)
    cat > "$out" <<'JSON'
{"projects":[{"Project":"a","Cost (USD)":1.23,"API Calls":10,"Sessions":1}],
 "periods":[{"label":"x","models":[
   {"Model":"claude-sonnet-5","Input Tokens":100,"Output Tokens":200,"Cache Read Tokens":300,"Cache Write Tokens":50}
 ]}]}
JSON
    echo "  Exported to: $out"
    ;;
  */wt-beta)
    echo "  No usage data found."
    ;;
  *)
    echo "fake-codeburn: unexpected --project $project" >&2
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/codeburn"
}

write_task_meta() {  # <file> <worktree> <harness> <model> [pr]
  local file=$1 worktree=$2 harness=$3 model=$4 pr=${5:-}
  {
    printf 'worktree=%s\n' "$worktree"
    printf 'harness=%s\n' "$harness"
    printf 'model=%s\n' "$model"
    [ -n "$pr" ] && printf 'pr=%s\n' "$pr"
  } > "$file"
}

# Joins a task with usage and one with no usage in the same run, and confirms
# the table carries cost, summed tokens (input+output+cache read+cache
# write), and the PR link through from meta - or a "-" placeholder when a task
# has neither usage nor a recorded PR yet.
test_joins_usage_by_worktree() {
  local tmp fakebin state out
  tmp=$(fm_test_tmproot fm-usage)
  fakebin=$(fm_fakebin "$tmp")
  make_fake_codeburn "$fakebin"
  state="$tmp/state"
  mkdir -p "$state"
  write_task_meta "$state/task-alpha.meta" "/worktrees/wt-alpha" claude sonnet \
    "https://github.com/example/repo/pull/9"
  write_task_meta "$state/task-beta.meta" "/worktrees/wt-beta" claude opus

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$USAGE" 2>&1) \
    || fail "fm-usage.sh exited non-zero: $out"

  assert_contains "$out" "task-alpha" "alpha task row missing"
  assert_contains "$out" '1.23' "alpha row missing joined cost"
  assert_contains "$out" "650" "alpha row missing summed tokens (100+200+300+50)"
  assert_contains "$out" "https://github.com/example/repo/pull/9" "alpha row missing PR link"
  local beta_line
  beta_line=$(printf '%s\n' "$out" | grep '^task-beta ')
  [ -n "$beta_line" ] || fail "beta task row missing"
  assert_contains "$beta_line" " 0 " "beta row (no usage data) should report zero tokens"
  assert_contains "$beta_line" "\$0" "beta row (no usage data) should report zero cost"
  pass "fm-usage.sh: joins state/*.meta to codeburn usage by worktree path"
}

# A meta file that never recorded worktree= (shouldn't happen for a live task,
# but is cheap to guard) is skipped with a warning rather than crashing the
# whole report.
test_skips_meta_without_worktree() {
  local tmp fakebin state out
  tmp=$(fm_test_tmproot fm-usage)
  fakebin=$(fm_fakebin "$tmp")
  make_fake_codeburn "$fakebin"
  state="$tmp/state"
  mkdir -p "$state"
  printf 'harness=claude\nmodel=sonnet\n' > "$state/task-noworktree.meta"
  write_task_meta "$state/task-alpha.meta" "/worktrees/wt-alpha" claude sonnet

  out=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$USAGE" 2>&1) \
    || fail "fm-usage.sh exited non-zero: $out"

  assert_contains "$out" "task-alpha" "alpha task row missing despite a broken sibling meta"
  assert_contains "$out" "skipping" "missing-worktree task should be skipped with a warning"
  pass "fm-usage.sh: skips a meta file with no worktree= instead of failing the whole report"
}

# No state/*.meta at all (a freshly bootstrapped or fully torn-down home) is
# not an error.
test_empty_state_dir_is_not_an_error() {
  local tmp state out code
  tmp=$(fm_test_tmproot fm-usage)
  state="$tmp/state"
  mkdir -p "$state"

  out=$(FM_STATE_OVERRIDE="$state" "$USAGE" 2>&1)
  code=$?
  expect_code 0 "$code" "fm-usage.sh with no tasks"
  assert_contains "$out" "no state" "empty-state message missing"
  pass "fm-usage.sh: an empty state dir reports cleanly instead of erroring"
}

test_script_parses
test_joins_usage_by_worktree
test_skips_meta_without_worktree
test_empty_state_dir_is_not_an_error
