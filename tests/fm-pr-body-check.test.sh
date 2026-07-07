#!/usr/bin/env bash
# Tests for bin/fm-pr-body-check.sh.
#
# Matrix:
#   (a) clean body passes (exit 0)
#   (b) body with a /var/folders path fails (exit non-zero)
#   (c) --ui body with no images at all fails
#   (d) raw.githubusercontent.com reference fails (always, not just --ui)
#   (e) --ui blob link only fails (blob links are click-through, not inline)
#   (f) --ui user-attachments/assets URL passes
#   (g) --ui <owner>/<repo>/assets URL passes
#   (h) malformed PR URL fails fast without calling gh
#   (i) body with a /private/tmp path fails
#   (j) body with an absolute /Users/... image path fails
#   (k) a gh fetch failure fails loudly rather than passing as a clean body
#   (l) --ui github.com/<owner>/<repo>/raw/<sha>/<path> URL passes
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pr-body-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-check-tests)

VALID_URL="https://github.com/owner/repo/pull/42"

# Build a sandbox with a fake `gh` that outputs $FM_TEST_PR_BODY.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s' "${FM_TEST_PR_BODY:-}"
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$case_dir"
}

run_check() {
  local case_dir=$1 body=$2
  shift 2
  FM_TEST_PR_BODY="$body" PATH="$case_dir/fakebin:$PATH" "$CHECK" "$@"
}

# (a) Clean body with no bad paths and no --ui passes.
test_clean_body_passes() {
  local case_dir
  case_dir=$(make_case clean)
  local body="## Summary

This change satisfies the login redirect requirement.

| Before | After |
|--------|-------|
| [Before screenshot](https://github.com/owner/repo/blob/main/docs/pr-screenshots/task-a1/before.png) | [After screenshot](https://github.com/owner/repo/blob/main/docs/pr-screenshots/task-a1/after.png) |"
  run_check "$case_dir" "$body" "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "clean body should pass"
  pass "fm-pr-body-check: clean body passes"
}

# (b) Body with a /var/folders path fails.
test_var_folders_path_fails() {
  local case_dir err rc
  case_dir=$(make_case var-folders)
  local body="Here is a screenshot: /var/folders/xy/abc123/screenshot.png"
  err=$(run_check "$case_dir" "$body" "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "body with /var/folders path should fail but passed"
  assert_contains "$err" "local filesystem path" "should name the problem"
  pass "fm-pr-body-check: /var/folders path fails"
}

# (c) --ui body with no images at all fails.
test_ui_no_images_fails() {
  local case_dir err rc
  case_dir=$(make_case ui-no-images)
  local body="## Summary

This satisfies the requirement. No screenshots included."
  err=$(run_check "$case_dir" "$body" --ui "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--ui body with no images should fail but passed"
  assert_contains "$err" "no inline images" "should name the problem"
  pass "fm-pr-body-check: --ui with no images fails"
}

# (d) raw.githubusercontent.com reference fails (always, not just --ui).
test_raw_githubusercontent_fails() {
  local case_dir err rc
  case_dir=$(make_case raw-githubusercontent)
  local body="![before](https://raw.githubusercontent.com/owner/repo/abc/docs/pr-screenshots/t1/before.png)"
  err=$(run_check "$case_dir" "$body" "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "body with raw.githubusercontent.com should fail but passed"
  assert_contains "$err" "raw.githubusercontent.com" "should name the problem"
  pass "fm-pr-body-check: raw.githubusercontent.com ref fails"
}

# (e) --ui with only a blob link fails (blob links are click-through, not inline images).
test_ui_blob_link_only_fails() {
  local case_dir err rc
  case_dir=$(make_case ui-blob-only)
  local body="| Before | After |
|--------|-------|
| [Before](https://github.com/owner/repo/blob/main/docs/pr-screenshots/task-t1/before.png) | [After](https://github.com/owner/repo/blob/main/docs/pr-screenshots/task-t1/after.png) |"
  err=$(run_check "$case_dir" "$body" --ui "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--ui body with only blob links should fail but passed"
  assert_contains "$err" "no inline images" "should explain blob links are not inline"
  pass "fm-pr-body-check: --ui with blob links only fails"
}

# (f) --ui body with a user-attachments/assets URL passes.
test_ui_user_attachments_passes() {
  local case_dir
  case_dir=$(make_case ui-user-attachments)
  local body="| Before | After |
|--------|-------|
| ![before](https://github.com/user-attachments/assets/abc-123-before.png) | ![after](https://github.com/user-attachments/assets/abc-123-after.png) |"
  run_check "$case_dir" "$body" --ui "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "--ui body with user-attachments/assets URL should pass"
  pass "fm-pr-body-check: --ui with user-attachments/assets URL passes"
}

# (g) --ui body with an <owner>/<repo>/assets URL passes.
test_ui_repo_assets_passes() {
  local case_dir
  case_dir=$(make_case ui-repo-assets)
  local body="![after](https://github.com/owner/repo/assets/12345/after.png)"
  run_check "$case_dir" "$body" --ui "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "--ui body with <owner>/<repo>/assets URL should pass"
  pass "fm-pr-body-check: --ui with <owner>/<repo>/assets URL passes"
}

# (h) Malformed PR URL fails fast without calling gh.
test_malformed_url_fails() {
  local case_dir err rc
  case_dir=$(make_case malformed-url)
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf 'gh-was-called\n' > "$case_dir/gh-called"
exit 0
SH
  err=$(FM_TEST_PR_BODY="" PATH="$case_dir/fakebin:$PATH" "$CHECK" "not-a-github-url" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "malformed URL should fail but passed"
  assert_absent "$case_dir/gh-called" "gh must not be called for a malformed URL"
  assert_contains "$err" "PR URL must match" "should report URL format error"
  pass "fm-pr-body-check: malformed URL fails fast"
}

# (i) Body with a /private/tmp path fails.
test_private_tmp_path_fails() {
  local case_dir rc
  case_dir=$(make_case private-tmp)
  local body="Screenshot at /private/tmp/claude-501/scratchpad/screenshot.png shows the fix."
  run_check "$case_dir" "$body" "$VALID_URL" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "body with /private/tmp path should fail but passed"
  pass "fm-pr-body-check: /private/tmp path fails"
}

# (j) Body with an absolute /Users/... image path fails.
test_users_image_path_fails() {
  local case_dir rc
  case_dir=$(make_case users-image)
  local body="![screenshot](/Users/andrew/Desktop/screenshot.png)"
  run_check "$case_dir" "$body" "$VALID_URL" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "body with /Users/... image path should fail but passed"
  pass "fm-pr-body-check: /Users/... image path fails"
}

# (k) A gh fetch failure (bad auth, network, deleted PR) fails loudly.
# An empty body from a *successful* fetch is clean; a *failed* fetch must not
# be mistaken for one, which is the PR-#11-class regression this guards.
test_gh_fetch_failure_fails() {
  local case_dir err rc
  case_dir=$(make_case gh-fetch-failure)
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'error: Could not resolve to a PullRequest\n' >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh"
  err=$(PATH="$case_dir/fakebin:$PATH" "$CHECK" "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "gh fetch failure should fail but passed"
  assert_contains "$err" "could not fetch PR body" "should report the fetch failure"
  pass "fm-pr-body-check: gh fetch failure fails loudly"
}

# (l) --ui body with a github.com/<owner>/<repo>/raw/<sha>/<path> URL passes.
# These are commit-sha raw URLs: they render inline for authenticated repo members
# on both public and private repos, unlike raw.githubusercontent.com which 404s on private repos.
test_ui_raw_sha_url_passes() {
  local case_dir
  case_dir=$(make_case ui-raw-sha)
  local body="| Before | After |
|--------|-------|
| ![before](https://github.com/owner/repo/raw/abc1234def5678/docs/pr-screenshots/task-t1/before.png) | ![after](https://github.com/owner/repo/raw/abc1234def5678/docs/pr-screenshots/task-t1/after.png) |"
  run_check "$case_dir" "$body" --ui "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "--ui body with github.com/<owner>/<repo>/raw/<sha>/... URL should pass"
  pass "fm-pr-body-check: --ui with github.com/<owner>/<repo>/raw/<sha>/<path> URL passes"
}

test_clean_body_passes
test_var_folders_path_fails
test_ui_no_images_fails
test_raw_githubusercontent_fails
test_ui_blob_link_only_fails
test_ui_user_attachments_passes
test_ui_repo_assets_passes
test_malformed_url_fails
test_private_tmp_path_fails
test_users_image_path_fails
test_gh_fetch_failure_fails
test_ui_raw_sha_url_passes
