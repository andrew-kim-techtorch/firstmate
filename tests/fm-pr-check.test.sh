#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh's non-skippable PR-body gate.
#
# fm-pr-check now runs the canonical PR-body substance gate (fm-pr-body-check.sh)
# before recording pr= or arming the merge poll, so a bare or pipeline-default
# body cannot be relayed as ready. These tests prove the wiring, not the gate's
# internal checks (those are owned by fm-pr-body-check.test.sh):
#   (1) a bare body fails and the merge poll is NOT armed
#   (2) a pipeline-default body fails and the merge poll is NOT armed
#   (3) a canonical body passes: pr= is recorded and the merge poll IS armed
#   (5) a local-path-only failure is auto-sanitized and retried: pr= is
#       recorded and the merge poll IS armed (fm-pr-body-sanitize.sh's own
#       behavior is owned by fm-pr-body-sanitize.test.sh)
#   (6) a local-path body that STILL fails after auto-sanitize (other
#       substance problems remain) fails and the merge poll is NOT armed
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# FM_ROOT must resolve to the real repo so fm-pr-check finds bin/fm-pr-body-check.sh
# and bin/fm-guard.sh; only the state HOME is redirected into a temp dir.
CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

ID=t1
VALID_URL="https://github.com/owner/repo/pull/42"

# A full canonical PR body that passes every fm-pr-body-check.sh check.
canonical_body() {
  cat <<'EOF'
**Requirement:** Bare and pipeline-default PR bodies must fail the substance gate.

## What changed
fm-pr-check now runs the body gate before arming the poll, read alongside the schematic.

```mermaid
flowchart LR
  crew --> check
```

## How it works
Given a pipeline-default body with `## Intent` and no `## Evidence`, the gate exits 1.

## Evidence
Testing suite:

| Suite | What it guards | Result | Command |
|-------|----------------|--------|---------|
| tests/fm-pr-check.test.sh | gate blocks bare, passes canonical | pass | bash tests/fm-pr-check.test.sh |

## Risks
None: additive gate on an existing wiring point.

## Links
Follow-on to #42.
EOF
}

# Same canonical body, but the Evidence table cell carries a /var/folders
# path the way the no-mistakes pipeline's own evidence step generates one:
# otherwise-canonical, so sanitizing it should make it pass.
canonical_body_with_local_path() {
  cat <<'EOF'
**Requirement:** Bare and pipeline-default PR bodies must fail the substance gate.

## What changed
fm-pr-check now runs the body gate before arming the poll, read alongside the schematic.

```mermaid
flowchart LR
  crew --> check
```

## How it works
Given a pipeline-default body with `## Intent` and no `## Evidence`, the gate exits 1.

## Evidence
Testing suite:

| Suite | What it guards | Result | Command |
|-------|----------------|--------|---------|
| tests/fm-pr-check.test.sh | gate blocks bare, passes canonical | pass, log at /var/folders/xy/abc123/evidence.log | bash tests/fm-pr-check.test.sh |

## Risks
None: additive gate on an existing wiring point.

## Links
Follow-on to #42.
EOF
}

# Build a per-case sandbox: a temp FM_HOME with state/<id>.meta and a fake `gh`
# that returns $FM_TEST_PR_BODY for the body query and a sha for the head query.
make_case() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf 'window=fm-%s\n' "$ID" > "$home/state/$ID.meta"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "headRefOid" ] && { printf 'deadbeefsha\n'; exit 0; }
done
printf '%s' "${FM_TEST_PR_BODY:-}"
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$home"
}

run_pr_check() {
  local home=$1 body=$2
  FM_TEST_PR_BODY="$body" FM_HOME="$home" PATH="$home/fakebin:$PATH" \
    "$CHECK" "$ID" "$VALID_URL"
}

# Build a per-case sandbox whose fake `gh` reads the PR body from a file (not a
# static env var) and whose fake `gh-axi pr edit` overwrites that file, so a
# fm-pr-check.sh run that internally re-fetches the body after invoking
# fm-pr-body-sanitize.sh observes the edit fm-pr-body-sanitize.sh made, the way
# a real gh/gh-axi pair against a live PR would.
make_stateful_case() {
  local name=$1 body=$2 home fakebin
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf 'window=fm-%s\n' "$ID" > "$home/state/$ID.meta"
  printf '%s' "$body" > "$home/pr-body.txt"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = "headRefOid" ] && { printf 'deadbeefsha\n'; exit 0; }
done
cat "$home/pr-body.txt"
SH
  cat > "$fakebin/gh-axi" <<SH
#!/usr/bin/env bash
cp "\${@: -1}" "$home/pr-body.txt"
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  printf '%s\n' "$home"
}

run_pr_check_stateful() {
  local home=$1
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$CHECK" "$ID" "$VALID_URL"
}

# (1) A bare one-line body fails and the merge poll is not armed.
test_bare_body_fails_and_no_arm() {
  local home err rc
  home=$(make_case bare)
  err=$(run_pr_check "$home" "Fixes the login redirect bug." 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bare body should fail fm-pr-check but passed"
  assert_contains "$err" "substance gate" "should surface the gate failure"
  assert_absent "$home/state/$ID.check.sh" "merge poll must not be armed on a failed body"
  pass "fm-pr-check: bare body fails, poll not armed"
}

# (2) A no-mistakes pipeline-default body fails and the merge poll is not armed.
test_pipeline_default_fails_and_no_arm() {
  local home rc
  home=$(make_case pipeline)
  local body="## Intent
Add the loader.

## What Changed
Wired it up.

## Testing
verified.

## Pipeline
green."
  run_pr_check "$home" "$body" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail "pipeline-default body should fail fm-pr-check but passed"
  assert_absent "$home/state/$ID.check.sh" "merge poll must not be armed on a pipeline-default body"
  pass "fm-pr-check: pipeline-default body fails, poll not armed"
}

# (3) A canonical body passes: pr= is recorded and the merge poll is armed.
test_canonical_body_passes_and_arms() {
  local home out rc
  home=$(make_case canonical)
  out=$(run_pr_check "$home" "$(canonical_body)" 2>&1); rc=$?
  expect_code 0 $rc "canonical body should pass fm-pr-check"
  assert_present "$home/state/$ID.check.sh" "merge poll must be armed on a canonical body"
  assert_grep "pr=$VALID_URL" "$home/state/$ID.meta" "pr= must be recorded on pass"
  assert_contains "$out" "armed" "should report the poll was armed"
  pass "fm-pr-check: canonical body passes, poll armed and pr= recorded"
}

# (4) FM_PR_CHECK_SKIP_BODY_GATE=1 bypasses the gate: a bare body passes, pr= is
# recorded, and the merge poll is armed. This is the merge-recording path that
# fm-pr-merge.sh uses after the captain already cleared the relay gate.
test_skip_env_bypasses_gate() {
  local home out rc
  home=$(make_case skip)
  out=$(FM_PR_CHECK_SKIP_BODY_GATE=1 FM_TEST_PR_BODY="Fixes the login redirect bug." \
    FM_HOME="$home" PATH="$home/fakebin:$PATH" "$CHECK" "$ID" "$VALID_URL" 2>&1); rc=$?
  expect_code 0 $rc "bare body should pass when the gate is skipped"
  assert_present "$home/state/$ID.check.sh" "merge poll must be armed when the gate is skipped"
  assert_grep "pr=$VALID_URL" "$home/state/$ID.meta" "pr= must be recorded when the gate is skipped"
  assert_contains "$out" "armed" "should report the poll was armed"
  pass "fm-pr-check: FM_PR_CHECK_SKIP_BODY_GATE=1 bypasses the gate"
}

# (5) A local-path-only failure is auto-sanitized and retried: the otherwise-
# canonical body passes on retry, pr= is recorded, and the merge poll is armed.
test_local_path_failure_is_auto_sanitized_and_arms() {
  local home out rc
  home=$(make_stateful_case local-path-recoverable "$(canonical_body_with_local_path)")
  out=$(run_pr_check_stateful "$home" 2>&1); rc=$?
  expect_code 0 $rc "local-path body should pass fm-pr-check after auto-sanitize"
  assert_contains "$out" "auto-sanitizing" "should report the auto-sanitize action"
  assert_present "$home/state/$ID.check.sh" "merge poll must be armed after auto-sanitize recovers the body"
  assert_grep "pr=$VALID_URL" "$home/state/$ID.meta" "pr= must be recorded after auto-sanitize recovers the body"
  assert_not_contains "$(cat "$home/pr-body.txt")" "/var/folders" "the PR body on record must no longer contain the local path"
  pass "fm-pr-check: local-path failure is auto-sanitized and retried, poll armed"
}

# (6) A local-path body that still fails after auto-sanitize (other substance
# problems remain, e.g. a bare body with a stray local path) fails and the
# merge poll is NOT armed.
test_local_path_failure_still_fails_after_sanitize() {
  local home out rc
  home=$(make_stateful_case local-path-unrecoverable \
    "Fixes the bug. See /var/folders/xy/abc123/evidence.log for proof.")
  out=$(run_pr_check_stateful "$home" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "bare body with a local path should still fail fm-pr-check after auto-sanitize"
  assert_contains "$out" "still fails the canonical substance gate after auto-sanitize" "should report the post-sanitize failure"
  assert_absent "$home/state/$ID.check.sh" "merge poll must not be armed when auto-sanitize does not fully recover the body"
  pass "fm-pr-check: local-path body still failing after auto-sanitize is not armed"
}

test_bare_body_fails_and_no_arm
test_pipeline_default_fails_and_no_arm
test_canonical_body_passes_and_arms
test_skip_env_bypasses_gate
test_local_path_failure_is_auto_sanitized_and_arms
test_local_path_failure_still_fails_after_sanitize
