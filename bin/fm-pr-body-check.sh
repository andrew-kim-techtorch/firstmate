#!/usr/bin/env bash
# Check a PR body for local filesystem paths that will not render for reviewers,
# and (with --ui) assert that the body contains at least one rendered image.
# Firstmate runs this before relaying a PR as ready; the PR body conventions
# in bin/fm-brief.sh's ship-brief scaffold are the one authoritative source of
# what crewmates are expected to follow.
# Usage: fm-pr-body-check.sh [--ui] <pr-url>
#   --ui  also assert the body contains at least one rendered image (![...] or <img ...>)
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
BODY=$(gh pr view "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" --json body -q '.body // ""' 2>/dev/null || true)

# Fail if the body references a local filesystem path that will not render on GitHub.
LOCAL_PATH_PAT='(/var/folders|/private/tmp|/Users/[^[:space:]]*\.(png|jpg|jpeg|gif|svg))'
if printf '%s' "$BODY" | grep -qE "$LOCAL_PATH_PAT"; then
  printf 'error: PR body contains a local filesystem path that will not render for reviewers\n' >&2
  exit 1
fi

# With --ui, fail if the body has no rendered images at all.
if [ "$UI" = 1 ]; then
  if ! printf '%s' "$BODY" | grep -qE '!\[.*\]\(|<img '; then
    printf 'error: PR body has no rendered images (--ui requires before/after screenshots)\n' >&2
    exit 1
  fi
fi

printf 'ok: PR body passes checks\n'
