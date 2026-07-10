#!/usr/bin/env bash
# Tests for bin/fm-pr-body-check.sh.
#
# The check enforces the canonical PR-body standard on SUBSTANCE, not just
# section presence, so a bare or no-mistakes-pipeline-default body must fail.
# Matrix:
#   Rendering/path checks (pre-existing):
#   (b) body with a /var/folders path fails
#   (d) raw.githubusercontent.com reference fails (always, not just --ui)
#   (c) --ui body with no images at all fails
#   (e) --ui blob link only fails (blob links are click-through, not inline)
#   (h) malformed PR URL fails fast without calling gh
#   (i) body with a /private/tmp path fails
#   (j) body with an absolute /Users/... image path fails
#   (k) a gh fetch failure fails loudly rather than passing as a clean body
#   Substance checks (new):
#   (s1) a real no-mistakes pipeline-default body fails
#   (s2) a body leading with a requirement but using pipeline section names fails
#   (s3) a bare one-line body fails
#   (s4) a canonical body missing the mermaid schematic fails
#   (s5) a canonical body whose Evidence is a lone vague claim fails
#   (s6) a canonical body with no Testing/Evidence table fails
#   (s7) --ui canonical-ish body with an inline image but no Before/After table fails
#   Canonical passes:
#   (a) full canonical body passes (no --ui)
#   (l) --ui canonical body with github.com/<owner>/<repo>/raw/<sha>/<path> URLs passes
#   (f) --ui canonical body with user-attachments/assets URLs passes
#   (g) --ui canonical body with <owner>/<repo>/assets URLs passes
#   (m) canonical body with a #N reference passes without a thread-link warning
#   (n) canonical body with no thread link exits 0 but emits a warning
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-pr-body-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-body-check-tests)

VALID_URL="https://github.com/owner/repo/pull/42"

# A full canonical PR body that passes every check, including --ui.
# Args (all optional): <links-line> <before-img-url> <after-img-url>.
canonical_body() {
  local links=${1:-'Follow-on to #42.'}
  local before=${2:-'https://github.com/owner/repo/raw/abc1234/docs/pr-screenshots/t1/before.png'}
  local after=${3:-'https://github.com/owner/repo/raw/abc1234/docs/pr-screenshots/t1/after.png'}
  cat <<EOF
**Requirement:** Bare and pipeline-default PR bodies must fail the substance check.

## What changed
The check now enforces canonical sections on substance, read alongside the schematic below.

\`\`\`mermaid
flowchart LR
  crew --> check
\`\`\`

## How it works
Given a pipeline-default body with \`## Intent\` and no \`## Evidence\`, the check exits 1 naming the gap.

## Evidence
Before/after:

| Before | After |
|--------|-------|
| ![before]($before) | ![after]($after) |

Testing suite:

| Suite | What it guards | Result | Command |
|-------|----------------|--------|---------|
| tests/fm-pr-body-check.test.sh | canonical passes, bare/pipeline fail | pass | bash tests/fm-pr-body-check.test.sh |

## Risks
None: advisory tooling, does not gate the pipeline.

## Links
$links
EOF
}

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

# --- rendering / path checks -------------------------------------------------

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

# --- substance checks -------------------------------------------------------

# (s1) A real no-mistakes pipeline-default body fails: it leads with ## Intent
# and never states the requirement, so it fails the lead-with-requirement check.
test_pipeline_default_body_fails() {
  local case_dir err rc
  case_dir=$(make_case pipeline-default)
  local body="## Intent
Add the seed loader.

## What Changed
Wired up the loader and guidance rendering.

## Risk Assessment
Low.

## Testing
verified seed load and guidance rendering

## Pipeline
Ran the gate; all green."
  err=$(run_check "$case_dir" "$body" "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "pipeline-default body should fail but passed"
  assert_contains "$err" "requirement" "should flag the missing requirement lead"
  pass "fm-pr-body-check: pipeline-default body fails"
}

# (s2) Leads with a requirement but uses the pipeline section names, so the
# distinctive canonical sections (How it works / Evidence / Links) are missing.
test_pipeline_section_names_fail() {
  local case_dir err rc
  case_dir=$(make_case pipeline-sections)
  local body="**Requirement:** Load the seed data on boot.

## Intent
Add the seed loader.

## What Changed
Wired it up.

## Testing
| Suite | What | Result | Command |
|-------|------|--------|---------|
| t.sh | it | pass | bash t.sh |

## Pipeline
green."
  err=$(run_check "$case_dir" "$body" "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "pipeline section names should fail but passed"
  assert_contains "$err" "missing canonical section" "should name the missing canonical sections"
  pass "fm-pr-body-check: pipeline section names fail"
}

# (s3) A bare one-line body fails.
test_bare_body_fails() {
  local case_dir rc
  case_dir=$(make_case bare)
  local body="Fixes the login redirect bug."
  run_check "$case_dir" "$body" "$VALID_URL" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "bare one-line body should fail but passed"
  pass "fm-pr-body-check: bare body fails"
}

# (s4) A canonical body with no fenced mermaid/erDiagram schematic fails.
test_missing_mermaid_fails() {
  local case_dir err rc
  case_dir=$(make_case missing-mermaid)
  local body='**Requirement:** Do the thing.

## What changed
Did it, but with no schematic.

## How it works
Given x, the result is y.

## Evidence
| Suite | What it guards | Result | Command |
|-------|----------------|--------|---------|
| t.sh | it works | pass | bash t.sh |

## Risks
None.

## Links
Follow-on to #1.'
  err=$(run_check "$case_dir" "$body" "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "canonical body missing mermaid should fail but passed"
  assert_contains "$err" "mermaid" "should flag the missing schematic"
  pass "fm-pr-body-check: missing mermaid schematic fails"
}

# (s5) A canonical body whose Evidence is a lone vague claim fails.
test_vague_evidence_fails() {
  local case_dir err rc
  case_dir=$(make_case vague-evidence)
  local body='**Requirement:** Do the thing.

## What changed
Did it.

```mermaid
flowchart LR
  a --> b
```

## How it works
Given x, the result is y.

## Evidence
verified seed load and guidance rendering

## Risks
None.

## Links
Follow-on to #1.'
  err=$(run_check "$case_dir" "$body" "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "vague Evidence should fail but passed"
  assert_contains "$err" "vague claim" "should flag the unsubstantiated Evidence"
  pass "fm-pr-body-check: vague Evidence claim fails"
}

# (s6) A canonical body with a substantiated-but-tableless Evidence still fails
# the "at least one table" requirement.
test_no_table_fails() {
  local case_dir err rc
  case_dir=$(make_case no-table)
  local body='**Requirement:** Do the thing.

## What changed
Did it.

```mermaid
flowchart LR
  a --> b
```

## How it works
Given x, the result is y.

## Evidence
<details><summary>run log</summary>
ran the suite, all green
</details>

## Risks
None.

## Links
Follow-on to #1.'
  err=$(run_check "$case_dir" "$body" "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "body with no table should fail but passed"
  assert_contains "$err" "Testing/Evidence table" "should flag the missing table"
  pass "fm-pr-body-check: body with no table fails"
}

# (s7) --ui body with an inline image but no | Before | After | table fails.
test_ui_no_before_after_table_fails() {
  local case_dir err rc
  case_dir=$(make_case ui-no-comparison)
  local body="![after](https://github.com/owner/repo/raw/abc1234/docs/pr-screenshots/t1/after.png)

Some notes, but no comparison table."
  err=$(run_check "$case_dir" "$body" --ui "$VALID_URL" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "--ui body with no Before/After table should fail but passed"
  assert_contains "$err" "Before | After" "should require the comparison table"
  pass "fm-pr-body-check: --ui with no Before/After table fails"
}

# --- canonical passes -------------------------------------------------------

# (a) Full canonical body passes (no --ui).
test_canonical_body_passes() {
  local case_dir
  case_dir=$(make_case canonical)
  run_check "$case_dir" "$(canonical_body)" "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "canonical body should pass"
  pass "fm-pr-body-check: canonical body passes"
}

# (l) --ui canonical body with github.com/<owner>/<repo>/raw/<sha>/<path> URLs passes.
test_ui_raw_sha_url_passes() {
  local case_dir
  case_dir=$(make_case ui-raw-sha)
  run_check "$case_dir" "$(canonical_body)" --ui "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "--ui canonical body with raw/<sha> URLs should pass"
  pass "fm-pr-body-check: --ui canonical raw/<sha> URLs pass"
}

# (f) --ui canonical body with user-attachments/assets URLs passes.
test_ui_user_attachments_passes() {
  local case_dir body
  case_dir=$(make_case ui-user-attachments)
  body=$(canonical_body 'Follow-on to #7.' \
    'https://github.com/user-attachments/assets/abc-before.png' \
    'https://github.com/user-attachments/assets/abc-after.png')
  run_check "$case_dir" "$body" --ui "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "--ui canonical body with user-attachments URLs should pass"
  pass "fm-pr-body-check: --ui user-attachments URLs pass"
}

# (g) --ui canonical body with <owner>/<repo>/assets URLs passes.
test_ui_repo_assets_passes() {
  local case_dir body
  case_dir=$(make_case ui-repo-assets)
  body=$(canonical_body 'Follow-on to #8.' \
    'https://github.com/owner/repo/assets/12345/before.png' \
    'https://github.com/owner/repo/assets/12345/after.png')
  run_check "$case_dir" "$body" --ui "$VALID_URL" >/dev/null 2>&1
  expect_code 0 $? "--ui canonical body with <owner>/<repo>/assets URLs should pass"
  pass "fm-pr-body-check: --ui <owner>/<repo>/assets URLs pass"
}

# (m) Canonical body with a #N reference passes without a thread-link warning.
test_body_with_issue_ref_no_warning() {
  local case_dir out
  case_dir=$(make_case issue-ref)
  out=$(run_check "$case_dir" "$(canonical_body 'Follow-on to #42.')" "$VALID_URL" 2>&1)
  expect_code 0 $? "canonical body with #N reference should pass"
  assert_not_contains "$out" "warning" "body with #N ref should not warn"
  pass "fm-pr-body-check: canonical body with #N reference passes without warning"
}

# (n) Canonical body with no thread link exits 0 but emits a warning.
test_body_no_thread_link_warns() {
  local case_dir out rc
  case_dir=$(make_case no-thread-link)
  out=$(run_check "$case_dir" "$(canonical_body 'Standalone change, no parent.')" "$VALID_URL" 2>&1); rc=$?
  expect_code 0 $rc "no thread link should exit 0 (lenient warning, not failure)"
  assert_contains "$out" "warning" "no thread link should emit a warning"
  assert_contains "$out" "thread link" "warning should name the problem"
  pass "fm-pr-body-check: no thread link exits 0 with warning"
}

test_var_folders_path_fails
test_ui_no_images_fails
test_raw_githubusercontent_fails
test_ui_blob_link_only_fails
test_malformed_url_fails
test_private_tmp_path_fails
test_users_image_path_fails
test_gh_fetch_failure_fails
test_pipeline_default_body_fails
test_pipeline_section_names_fail
test_bare_body_fails
test_missing_mermaid_fails
test_vague_evidence_fails
test_no_table_fails
test_ui_no_before_after_table_fails
test_canonical_body_passes
test_ui_raw_sha_url_passes
test_ui_user_attachments_passes
test_ui_repo_assets_passes
test_body_with_issue_ref_no_warning
test_body_no_thread_link_warns
