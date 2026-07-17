#!/usr/bin/env bash
# Check a PR body for SUBSTANCE against the canonical PR-body standard, so a bare
# or no-mistakes-pipeline-default body fails rather than passing on section
# presence alone. Also checks for screenshot references that will not render for
# reviewers, and (with --ui) asserts an inline image URL and a before/after table.
# Firstmate runs this before relaying a PR as ready.
# The canonical standard is specified in data/notes/pr-body-template.md and
# demonstrated in full by bin/fm-brief.sh's ship-brief scaffold (the filled
# reference body); this script enforces that same standard and does not restate it.
# Usage: fm-pr-body-check.sh [--ui] <pr-url>
#   --ui  also assert the body contains at least one inline image URL.
#         Accepted inline URL forms:
#           github.com/<owner>/<repo>/raw/<sha>/<path>  (commit-sha raw URLs render on private repos)
#           github.com/user-attachments/assets/...      (GitHub attachment)
#           github.com/<owner>/<repo>/assets/...        (GitHub attachment, legacy form)
#         Blob links (github.com/.../blob/...) are click-through only and do NOT satisfy this.
# Always fails on: local filesystem paths, raw.githubusercontent.com refs
#   (raw.githubusercontent.com returns 404 on private repos; use the github.com/.../raw/... form).
# Exit 0 on pass (one ok line to stdout); non-zero with a one-line reason to stderr on fail.
set -eu

UI=0
URL=
for a in "$@"; do
  case "$a" in
    --ui) UI=1 ;;
    -*)   printf 'error: unknown flag: %s\n' "$a" >&2; exit 1 ;;
    *)    URL=$a ;;
  esac
done
[ -n "$URL" ] || { printf 'usage: fm-pr-body-check.sh [--ui] <pr-url>\n' >&2; exit 1; }

# Same URL regex as bin/fm-pr-merge.sh.
# Sets PR_OWNER, PR_REPO, PR_NUMBER as globals on success.
parse_pr_url() {
  local url=$1
  if [[ "$url" =~ ^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]+)/pull/([0-9]+)/?$ ]]; then
    PR_OWNER="${BASH_REMATCH[1]}"
    PR_REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    if [[ "$PR_OWNER" != *- ]]; then
      return 0
    fi
  fi
  printf 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number> (got: %s)\n' "$url" >&2
  return 1
}

parse_pr_url "$URL" || exit 1

# Fetch the PR body as plain text.
# Use `gh` directly for JSON queries; gh-axi does not expose --json/-q.
# A fetch failure (bad auth, network, deleted/renamed PR, wrong repo) must fail
# loudly rather than looking like a clean empty body and passing the check.
if ! BODY=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json body -q '.body // ""' 2>/dev/null); then
  printf 'error: could not fetch PR body for %s/%s#%s (check auth, network, and that the PR exists)\n' "$PR_OWNER" "$PR_REPO" "$PR_NUMBER" >&2
  exit 1
fi

# Fail if the body references a local filesystem path that will not render on GitHub.
LOCAL_PATH_PAT='(/var/folders|/private/tmp|/Users/[^[:space:]]*\.(png|jpg|jpeg|gif|svg))'
if printf '%s' "$BODY" | grep -qE "$LOCAL_PATH_PAT"; then
  printf 'error: PR body contains a local filesystem path that will not render for reviewers\n' >&2
  exit 1
fi

# Fail if the body references raw.githubusercontent.com - those return 404 on private repos.
# Use github.com/<owner>/<repo>/raw/<sha>/<path> instead (renders inline for authenticated members).
if printf '%s' "$BODY" | grep -qF 'raw.githubusercontent.com'; then
  printf 'error: PR body references raw.githubusercontent.com which returns 404 on private repos; use github.com/<owner>/<repo>/raw/<sha>/<path> instead\n' >&2
  exit 1
fi

# With --ui, fail if the body has no inline image URLs.
# Accepted: github.com/<owner>/<repo>/raw/<sha>/... (commit-sha raw, renders on private repos)
#           github.com/user-attachments/assets/...  (GitHub attachment)
#           github.com/<owner>/<repo>/assets/...    (GitHub attachment, legacy form)
# NOT accepted: blob links (github.com/.../blob/...) - click-through only, not inline.
if [ "$UI" = 1 ]; then
  INLINE_IMG_PAT='github\.com/(user-attachments/assets/|[^/]+/[^/]+/raw/|[^/]+/[^/]+/assets/)'
  if ! printf '%s' "$BODY" | grep -qE "$INLINE_IMG_PAT"; then
    printf 'error: PR body has no inline images (--ui requires before/after screenshots using github.com/<owner>/<repo>/raw/<sha>/... URLs or GitHub attachment URLs; blob links are not inline)\n' >&2
    exit 1
  fi
  # A UI change must present the screenshots in a | Before | After | table.
  if ! printf '%s' "$BODY" | grep -qiE '^[[:space:]]*\|[[:space:]]*before[[:space:]]*\|[[:space:]]*after[[:space:]]*\|'; then
    printf 'error: --ui requires a "| Before | After |" screenshot comparison table\n' >&2
    exit 1
  fi
fi

# --- Substance checks: reject a bare body or the no-mistakes pipeline default. ---
# The canonical standard (data/notes/pr-body-template.md, demonstrated in
# bin/fm-brief.sh) requires real content, not just section headings.

# Must lead with the requirement being satisfied, not the pipeline's ## Intent.
if ! printf '%s\n' "$BODY" | head -n 8 | grep -qiE '(\*\*Requirement|^#{1,6}[[:space:]]*Requirement|^Requirement:)'; then
  printf 'error: PR body must lead with the requirement it satisfies (e.g. "**Requirement:** ...") near the top\n' >&2
  exit 1
fi

# Must use the canonical section names, not the pipeline defaults
# (## Intent / ## What Changed / ## Risk Assessment / ## Testing / ## Pipeline).
missing=
for s in "What changed" "How it works" "Evidence" "Risks" "Links"; do
  if ! printf '%s' "$BODY" | grep -qiE "^#{1,6}[[:space:]]+${s}([[:space:]]|\$)"; then
    missing="${missing:+$missing, }$s"
  fi
done
if [ -n "$missing" ]; then
  printf 'error: PR body missing canonical section(s): %s (a bare or pipeline-default body fails; rewrite to the fm-brief.sh template)\n' "$missing" >&2
  exit 1
fi

# The What changed section must carry a fenced mermaid/erDiagram schematic.
if ! printf '%s' "$BODY" | grep -qE '^[[:space:]]*```[[:space:]]*(mermaid|erDiagram)'; then
  printf 'error: PR body has no fenced ```mermaid (or erDiagram) schematic in the What changed section\n' >&2
  exit 1
fi

# --- Mermaid safety: a fence that PARSES, not just exists. ---
# GitHub's renderer silently shows "Unable to render rich display" on a broken
# diagram, so a body can pass the presence check above and still ship broken.
# Layer 1 (always on): a conservative pattern linter for the known-bad shapes -
# unquoted special chars in a label, and a literal \n instead of <br/>.
# It only flags a label when the FIRST character inside the delimiter is plain
# text, so legitimate double-delimiter shapes (cylinder [(...)], stadium
# ([...]), subroutine [[...]], hexagon {{...}}) and fully-quoted labels never
# false-positive; it can still miss a bad label buried past a quoted prefix,
# which is the deliberate false-negative bias this linter takes.
MERMAID_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-body-mermaid.XXXXXX")
trap 'rm -rf "$MERMAID_TMP"' EXIT

MERMAID_LINT_ERR=$(printf '%s\n' "$BODY" | awk -v outdir="$MERMAID_TMP" '
  BEGIN { in_block = 0; ln = 0; blk = 0 }
  {
    ln++
    line = $0
    if (in_block) {
      if (line ~ /^[[:space:]]*```[[:space:]]*$/) { in_block = 0; close(outfile); next }
      print line >> outfile
      if (line ~ /\\n/) {
        printf("line %d: literal backslash-n found - use <br/> for a line break: %s\n", ln, line)
      }
      if (line ~ /\[[^]"(][^]"]*[()<>&=][^]]*\]/) {
        printf("line %d: unquoted special character in a [label] - quote it: %s\n", ln, line)
      }
      if (line ~ /\([^)"[][^)"]*[][<>&=][^)]*\)/) {
        printf("line %d: unquoted special character in a (label) - quote it: %s\n", ln, line)
      }
      if (line ~ /\{[^}"{][^}"]*[()<>&=][^}]*\}/) {
        printf("line %d: unquoted special character in a {label} - quote it: %s\n", ln, line)
      }
      if (line ~ /\|[^|"][^|"]*[()<>&=][^|]*\|/) {
        printf("line %d: unquoted special character in an |edge label| - quote it: %s\n", ln, line)
      }
      next
    }
    if (line ~ /^[[:space:]]*```[[:space:]]*(mermaid|erDiagram)/) {
      in_block = 1
      blk++
      outfile = outdir "/block" blk ".mmd"
      printf "" > outfile
    }
  }
')
if [ -n "$MERMAID_LINT_ERR" ]; then
  printf 'error: PR body has an unsafe mermaid diagram (renders "Unable to render rich display" on GitHub):\n%s\n' "$MERMAID_LINT_ERR" >&2
  exit 1
fi

# Layer 2 (optional, authoritative): actually parse each block when a mermaid
# CLI is on PATH. Skips cleanly when mmdc is absent so the check still works
# without it - this is a bonus gate, not a hard dependency.
# A non-zero mmdc exit is only trusted as a real defect when its stderr carries
# a recognized mermaid parse-error signature. An installed-but-broken mmdc
# (headless Chromium/puppeteer cannot launch, ENOENT, etc.), a hang that times
# out, or any unrecognized output is downgraded to an advisory warning and
# PASSES, so a misconfigured mmdc can never block this non-skippable PR-relay
# gate. Layer 1 stays the always-on hard gate.
if command -v mmdc >/dev/null 2>&1; then
  MMDC_PARSE_ERR=
  MMDC_INFRA_ERR=
  PARSE_SIG='Parse error|Expecting|Syntax error|Lexical error|UnknownDiagramError|No diagram type detected'
  # mmdc launches headless Chromium and can hang rather than exit; guard it with
  # a timeout when one is on PATH (macOS lacks `timeout` by default, but coreutils
  # ships `gtimeout`). A timeout (exit 124) is treated as an infra failure and
  # downgraded, never a hard fail, so a wedged Chromium can never stall the gate.
  MMDC_TIMEOUT=
  if command -v timeout >/dev/null 2>&1; then
    MMDC_TIMEOUT="timeout 60"
  elif command -v gtimeout >/dev/null 2>&1; then
    MMDC_TIMEOUT="gtimeout 60"
  fi
  for f in "$MERMAID_TMP"/block*.mmd; do
    [ -e "$f" ] || continue
    rc=0
    # shellcheck disable=SC2086  # MMDC_TIMEOUT is an intentional word-split prefix
    $MMDC_TIMEOUT mmdc -i "$f" -o "$f.svg" >/dev/null 2>"$f.err" || rc=$?
    [ "$rc" -eq 0 ] && continue
    line1=$(head -n 1 "$f.err" 2>/dev/null)
    if [ "$rc" -ne 124 ] && grep -qiE "$PARSE_SIG" "$f.err" 2>/dev/null; then
      MMDC_PARSE_ERR="${MMDC_PARSE_ERR:+$MMDC_PARSE_ERR$(printf '\n')}$(basename "$f"): $line1"
    else
      [ "$rc" -eq 124 ] && line1="timed out (mmdc hung; likely a broken headless Chromium)"
      MMDC_INFRA_ERR="${MMDC_INFRA_ERR:+$MMDC_INFRA_ERR$(printf '\n')}$(basename "$f"): $line1"
    fi
  done
  if [ -n "$MMDC_PARSE_ERR" ]; then
    printf 'error: mermaid diagram failed to parse (mmdc):\n%s\n' "$MMDC_PARSE_ERR" >&2
    exit 1
  fi
  if [ -n "$MMDC_INFRA_ERR" ]; then
    printf 'warning: mmdc could not verify a mermaid diagram (not a parse error; likely a broken mmdc install - skipping the optional mmdc gate):\n%s\n' "$MMDC_INFRA_ERR" >&2
  fi
fi

# The Evidence section must be substantiated inline, not a lone vague claim
# like "verified seed load and guidance rendering" - require a table row,
# a <details> block, or command/code output within the section body.
EVIDENCE=$(printf '%s\n' "$BODY" | awk '
  /^#{1,6}[[:space:]]+[Ee]vidence/ { in_e=1; next }
  in_e && /^#{1,6}[[:space:]]/ { in_e=0 }
  in_e { print }
')
# shellcheck disable=SC2016  # single quotes are intentional: literal regex, no shell expansion
if ! printf '%s' "$EVIDENCE" | grep -qE '(\|.*\|.*\||<details>|```|`[^`]+`|^\$ )'; then
  printf 'error: Evidence section is a vague claim with no table, <details>, or command output; show the evidence inline\n' >&2
  exit 1
fi

# Must contain at least one Testing/Evidence table row.
if ! printf '%s' "$BODY" | grep -qE '^[[:space:]]*\|.*\|.*\|'; then
  printf 'error: PR body has no Testing/Evidence table; add a "| Suite | What it guards | Result | Command |" table with real rows\n' >&2
  exit 1
fi

# Lenient warning: flag a body with no thread link at all.
# A genuinely standalone first-of-its-kind PR has no parent, so this exits 0.
# The goal is to catch the common miss - a follow-on that forgot to link.
THREAD_PAT='#[0-9]|Part of|Follow-on to|Fixes'
if ! printf '%s' "$BODY" | grep -qE "$THREAD_PAT"; then
  printf 'warning: PR body has no thread link; add "Follow-on to #N", "Part of #N", or "Fixes #N" for follow-on and workstream PRs\n' >&2
fi

printf 'ok: PR body passes checks\n'
