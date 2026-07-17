#!/usr/bin/env bash
# Auto-sanitize a PR body's local-filesystem evidence-path references so it
# passes bin/fm-pr-body-check.sh's rendering gate, instead of a manual rewrite.
#
# Why this exists: the no-mistakes pipeline's test-evidence step keeps
# artifacts (screenshots, logs) in a temp dir whenever test.evidence.store_in_repo
# is off, and then references that temp path by literal filesystem path
# (/var/folders/..., /private/tmp/..., /Users/....png) in the PR body it
# generates. That path never renders for a reviewer and fails
# fm-pr-body-check.sh's local-path gate every time it recurs. This script
# replaces every local-path reference in the body with a plain-text
# placeholder so the row's substance survives (a reviewer sees "local
# evidence, not committed to the repo" instead of a dead path) and the gate's
# local-path check passes on retry.
#
# Idempotent: re-running on an already-sanitized body finds nothing to change
# and exits 0 without editing the PR.
# Usage: fm-pr-body-sanitize.sh <pr-url>
set -eu

URL=${1:?usage: fm-pr-body-sanitize.sh <pr-url>}

# Same URL regex as bin/fm-pr-body-check.sh and bin/fm-pr-merge.sh.
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

# Use `gh` directly for the JSON body fetch; gh-axi does not expose --json/-q.
if ! BODY=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json body -q '.body // ""' 2>/dev/null); then
  printf 'error: could not fetch PR body for %s/%s#%s (check auth, network, and that the PR exists)\n' "$PR_OWNER" "$PR_REPO" "$PR_NUMBER" >&2
  exit 1
fi

# Excluded-char class covers the common terminators around a path reference in
# markdown: a closing paren/bracket (image syntax), a table pipe, or whitespace.
PLACEHOLDER='(local evidence, not committed to the repo)'
SANITIZED=$(printf '%s\n' "$BODY" | sed -E \
  -e "s#/var/folders/[^])| ]+#${PLACEHOLDER}#g" \
  -e "s#/private/tmp/[^])| ]+#${PLACEHOLDER}#g" \
  -e "s#/Users/[^])| ]*\\.(png|jpg|jpeg|gif|svg)#${PLACEHOLDER}#g")

# The trailing newline sed's here-string adds must not itself count as a change.
if [ "$SANITIZED" = "$(printf '%s\n' "$BODY")" ]; then
  printf 'ok: no local filesystem paths found in PR body, nothing to sanitize\n'
  exit 0
fi

TMPFILE=$(mktemp "${TMPDIR:-/tmp}/fm-pr-body-sanitize.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT
printf '%s' "$SANITIZED" > "$TMPFILE"

gh-axi pr edit "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --body-file "$TMPFILE" >/dev/null

printf 'ok: sanitized local filesystem evidence paths in %s\n' "$URL"
