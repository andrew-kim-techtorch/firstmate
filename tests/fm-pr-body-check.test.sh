#!/usr/bin/env bash
# Tests for bin/fm-pr-body-check.sh.
#
# Matrix:
#   (a) clean body passes (exit 0)
#   (b) body with a /var/folders path fails (exit non-zero)
#   (c) --ui body with no images fails (exit non-zero)
#   (d) --ui body with a markdown image passes (exit 0)
#   (e) --ui body with an <img ...> tag passes (exit 0)
#   (f) malformed PR URL fails fast without calling gh
#   (g) body with a /private/tmp path fails (exit non-zero)
#   (h) body with an absolute /Users/... image path fails (exit non-zero)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pr-body-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-check-tests)

VALID_URL="https://github.com/owner/repo/pull/42"

# Build a sandbox with a fake `gh` that outputs $FM_TEST_PR_BODY on
# `gh pr view ... --json body -q ...`.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$case_dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Emit the body for any `gh pr view ... --json body` call.
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

# (a) Clean body with no local paths passes.
test_clean_body_passes() {
  local case_dir
  case_dir=$(make_case clean)
  local body="## Summary

This change satisfies the login redirect requirement.

![Before](https://raw.githubusercontent.com/owner/repo/abc123/docs/pr-screenshots/task-a1/before.png) | ![After](https://raw.githubusercontent.com/owner/repo/abc123/docs/pr-screenshots/task-a1/after.png)"
  run_check "$case_dir" "$body" "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "clean body should pass"
  pass "fm-pr-body-check: clean body passes"
}

# (b) Body with a /var/folders path fails.
test_var_folders_path_fails() {
  local case_dir err
  case_dir=$(make_case var-folders)
  local body="Here is a screenshot: /var/folders/xy/abc123/screenshot.png"
  err=$(run_check "$case_dir" "$body" "$VALID_URL" 2>&1) && {
    fail "body with /var/folders path should fail but passed"
  }
  expect_code 1 $? "body with /var/folders path should exit non-zero"
  assert_contains "$err" "local filesystem path" "should name the problem"
  pass "fm-pr-body-check: /var/folders path fails"
}

# (c) --ui body with no images fails.
test_ui_no_images_fails() {
  local case_dir err
  case_dir=$(make_case ui-no-images)
  local body="## Summary

This satisfies the requirement. No screenshots included."
  err=$(run_check "$case_dir" "$body" --ui "$VALID_URL" 2>&1) && {
    fail "--ui body with no images should fail but passed"
  }
  expect_code 1 $? "--ui body with no images should exit non-zero"
  assert_contains "$err" "no rendered images" "should name the problem"
  pass "fm-pr-body-check: --ui with no images fails"
}

# (d) --ui body with a raw.githubusercontent.com markdown image passes.
test_ui_markdown_image_passes() {
  local case_dir
  case_dir=$(make_case ui-markdown-image)
  local body="## Summary

| Before | After |
|--------|-------|
| ![before](https://raw.githubusercontent.com/owner/repo/abc/docs/pr-screenshots/t1/before.png) | ![after](https://raw.githubusercontent.com/owner/repo/abc/docs/pr-screenshots/t1/after.png) |"
  run_check "$case_dir" "$body" --ui "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "--ui body with a markdown image should pass"
  pass "fm-pr-body-check: --ui with markdown image passes"
}

# (e) --ui body with an <img ...> tag passes.
test_ui_img_tag_passes() {
  local case_dir
  case_dir=$(make_case ui-img-tag)
  local body="<img src='https://user-images.githubusercontent.com/123/screenshot.png' alt='after'>"
  run_check "$case_dir" "$body" --ui "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "--ui body with an <img> tag should pass"
  pass "fm-pr-body-check: --ui with <img> tag passes"
}

# (f) Malformed PR URL fails fast without calling gh.
test_malformed_url_fails() {
  local case_dir err rc
  case_dir=$(make_case malformed-url)
  # Use a gh mock that writes a sentinel if called, to detect gh invocation.
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

# (g) Body with a /private/tmp path fails.
test_private_tmp_path_fails() {
  local case_dir
  case_dir=$(make_case private-tmp)
  local body="Screenshot at /private/tmp/claude-501/scratchpad/screenshot.png shows the fix."
  run_check "$case_dir" "$body" "$VALID_URL" >/dev/null 2>&1 && {
    fail "body with /private/tmp path should fail but passed"
  }
  expect_code 1 $? "body with /private/tmp path should exit non-zero"
  pass "fm-pr-body-check: /private/tmp path fails"
}

# (h) Body with an absolute /Users/... image path fails.
test_users_image_path_fails() {
  local case_dir
  case_dir=$(make_case users-image)
  local body="![screenshot](/Users/andrew/Desktop/screenshot.png)"
  run_check "$case_dir" "$body" "$VALID_URL" >/dev/null 2>&1 && {
    fail "body with /Users/... image path should fail but passed"
  }
  expect_code 1 $? "body with /Users/... image path should exit non-zero"
  pass "fm-pr-body-check: /Users/... image path fails"
}

test_clean_body_passes
test_var_folders_path_fails
test_ui_no_images_fails
test_ui_markdown_image_passes
test_ui_img_tag_passes
test_malformed_url_fails
test_private_tmp_path_fails
test_users_image_path_fails
