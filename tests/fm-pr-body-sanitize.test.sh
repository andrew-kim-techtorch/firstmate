#!/usr/bin/env bash
# Tests for bin/fm-pr-body-sanitize.sh.
#
# The sanitizer strips no-mistakes-pipeline-generated local filesystem evidence
# paths out of a PR body so bin/fm-pr-body-check.sh's local-path gate can pass
# on retry, instead of forcing a manual rewrite. Matrix:
#   (a) a /var/folders table-cell reference is replaced and the PR is edited
#   (b) a /private/tmp reference is replaced
#   (c) a /Users/....png image reference is replaced
#   (d) a clean body with no local paths is a no-op: gh-axi is never called
#   (e) the sanitized body no longer trips fm-pr-body-check.sh's local-path gate
#   (f) malformed PR URL fails fast without calling gh
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SANITIZE="$ROOT/bin/fm-pr-body-sanitize.sh"
CHECK="$ROOT/bin/fm-pr-body-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-sanitize-tests)

VALID_URL="https://github.com/owner/repo/pull/42"

# Build a sandbox with a fake `gh` that reads $FM_TEST_PR_BODY and a fake
# `gh-axi` that records its args and captures the edited body to a file.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' "${FM_TEST_PR_BODY:-}"
SH
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$case_dir/gh-axi.args"
# Last arg is the --body-file path.
cp "\${@: -1}" "$case_dir/edited-body.txt"
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  printf '%s\n' "$case_dir"
}

run_sanitize() {
  local case_dir=$1 body=$2
  FM_TEST_PR_BODY="$body" PATH="$case_dir/fakebin:$PATH" "$SANITIZE" "$VALID_URL"
}

# (a) A /var/folders table-cell reference is replaced and the PR is edited.
test_var_folders_replaced() {
  local case_dir out rc edited
  case_dir=$(make_case var-folders)
  local body="| Suite | Result |
|-------|--------|
| t.sh | pass, log at /var/folders/xy/abc123/evidence.log |"
  out=$(run_sanitize "$case_dir" "$body" 2>&1); rc=$?
  expect_code 0 "$rc" "sanitize should succeed on a /var/folders path"
  assert_contains "$out" "sanitized" "should report a sanitize action"
  assert_present "$case_dir/gh-axi.args" "gh-axi pr edit should have been invoked"
  edited=$(cat "$case_dir/edited-body.txt")
  assert_not_contains "$edited" "/var/folders" "edited body must not contain the local path"
  assert_contains "$edited" "not committed to the repo" "edited body should carry the placeholder"
  pass "fm-pr-body-sanitize: /var/folders path is replaced and PR edited"
}

# (b) A /private/tmp reference is replaced.
test_private_tmp_replaced() {
  local case_dir edited
  case_dir=$(make_case private-tmp)
  local body="Screenshot at /private/tmp/claude-501/scratchpad/screenshot.png shows the fix."
  run_sanitize "$case_dir" "$body" >/dev/null 2>&1
  edited=$(cat "$case_dir/edited-body.txt")
  assert_not_contains "$edited" "/private/tmp" "edited body must not contain the local path"
  pass "fm-pr-body-sanitize: /private/tmp path is replaced"
}

# (c) A /Users/....png image reference is replaced.
test_users_image_replaced() {
  local case_dir edited
  case_dir=$(make_case users-image)
  local body="![screenshot](/Users/andrew/Desktop/screenshot.png)"
  run_sanitize "$case_dir" "$body" >/dev/null 2>&1
  edited=$(cat "$case_dir/edited-body.txt")
  assert_not_contains "$edited" "/Users/andrew" "edited body must not contain the local path"
  pass "fm-pr-body-sanitize: /Users/....png path is replaced"
}

# (d) A clean body with no local paths is a no-op: gh-axi is never called.
test_clean_body_is_noop() {
  local case_dir out rc
  case_dir=$(make_case clean)
  out=$(run_sanitize "$case_dir" "A clean body with no local paths at all." 2>&1); rc=$?
  expect_code 0 "$rc" "sanitize should exit 0 on a clean body"
  assert_contains "$out" "nothing to sanitize" "should report a no-op"
  assert_absent "$case_dir/gh-axi.args" "gh-axi must not be called when there is nothing to sanitize"
  pass "fm-pr-body-sanitize: clean body is a no-op, gh-axi not invoked"
}

# (e) The sanitized body no longer trips fm-pr-body-check.sh's local-path gate.
test_sanitized_body_passes_local_path_gate() {
  local case_dir fakebin err rc
  case_dir=$(make_case gate-retry)
  local body="Evidence log at /var/folders/xy/abc123/evidence.log confirms the fix."
  run_sanitize "$case_dir" "$body" >/dev/null 2>&1
  fakebin="$case_dir/fakebin"
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
cat "$case_dir/edited-body.txt"
SH
  chmod +x "$fakebin/gh"
  err=$(PATH="$fakebin:$PATH" "$CHECK" "$VALID_URL" 2>&1); rc=$?
  # The sanitized body still fails other substance checks (it is not a full
  # canonical body), but it must not fail on the local-path gate specifically.
  assert_not_contains "$err" "local filesystem path" "sanitized body must not re-trip the local-path gate"
  pass "fm-pr-body-sanitize: sanitized body clears fm-pr-body-check.sh's local-path gate"
}

# (f) Malformed PR URL fails fast without calling gh.
test_malformed_url_fails() {
  local case_dir err rc
  case_dir=$(make_case malformed-url)
  err=$(FM_TEST_PR_BODY="" PATH="$case_dir/fakebin:$PATH" "$SANITIZE" "not-a-github-url" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "malformed URL should fail but passed"
  assert_absent "$case_dir/gh-axi.args" "gh-axi must not be called for a malformed URL"
  assert_contains "$err" "PR URL must match" "should report URL format error"
  pass "fm-pr-body-sanitize: malformed URL fails fast"
}

test_var_folders_replaced
test_private_tmp_replaced
test_users_image_replaced
test_clean_body_is_noop
test_sanitized_body_passes_local_path_gate
test_malformed_url_fails
