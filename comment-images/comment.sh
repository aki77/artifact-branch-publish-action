#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# artifact-branch-comment-images
#
# Helper script for the comment-images composite action. Mode is selected by
# the first argument. This script is env-driven and resolves relative paths
# against the current working directory (== GITHUB_WORKSPACE), mirroring the
# style of publish.sh.
#
# Modes:
#   detect  - expand FILES globs, produce a relative-path list + matched flag
#   build   - turn the detected file list into a markdown comment body
# =============================================================================

MODE="${1:-}"

# --- detect ------------------------------------------------------------------
# Expand the FILES globs into a stable, de-duplicated list of relative paths.
# Unlike publish.sh, zero matches is NOT an error here: the caller simply skips
# publishing/commenting when nothing matched.
detect() {
  # globstar: `**` recurses (bash 4+, best effort). nullglob: a non-matching
  # pattern expands to nothing rather than being kept literally.
  shopt -s globstar 2>/dev/null || true
  shopt -s nullglob

  : "${FILES:?FILES is required}"

  # $FILES is intentionally unquoted so that multiple patterns separated by
  # whitespace expand independently. With the default IFS this splits on BOTH
  # spaces and newlines, so `files:` may be written either way (or mixed).
  # Strip a leading ./ so paths are canonical (a/b.gif, not ./a/b.gif), then
  # sort/de-dup and drop any empty line so the list holds exactly the matches.
  # shellcheck disable=SC2086
  local list
  list=$(for f in $FILES; do printf '%s\n' "${f#./}"; done | sort -u | sed '/^$/d')

  local matched="false"
  if [ -n "$list" ]; then
    matched="true"
  fi

  # Write the file list (one relative path per line) where build can read it.
  # RUNNER_TEMP is normally set by GitHub; tests override it. Empty $list must
  # yield an empty file (no stray blank line), so guard the newline.
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  if [ -n "$list" ]; then
    printf '%s\n' "$list" > "$RUNNER_TEMP/files.txt"
  else
    : > "$RUNNER_TEMP/files.txt"
  fi

  # GITHUB_OUTPUT may be absent (e.g. local runs) - guard so we never fail.
  printf 'matched=%s\n' "$matched" >> "${GITHUB_OUTPUT:-/dev/null}"

  # Zero matches is a valid, non-error outcome.
  return 0
}

# Percent-encode a relative path for use inside a markdown link URL, one path
# segment at a time so the `/` separators stay intact. Needed because
# screenshot/E2E tooling commonly produces filenames with spaces, parentheses,
# or non-ASCII characters, which would otherwise break the `![alt](url)` link
# or (for multi-byte characters) get encoded as Unicode code points rather
# than UTF-8 bytes if done by hand in bash. Delegated to node (bundled on
# GitHub-hosted runners) since encodeURIComponent already does this correctly.
urlencode_path() {
  node -e '
    console.log(
      process.argv[1]
        .split("/")
        .map(encodeURIComponent)
        .join("/")
    )
  ' "$1"
}

# Escape `[`, `]`, and `\` in a relative path so it can be safely used as the
# alt text of a markdown image link (`![<alt>](...)`). Unescaped `]` would
# otherwise close the alt text early and break the link.
escape_markdown_alt() {
  node -e 'console.log(process.argv[1].replace(/[\\\[\]]/g, "\\$&"))' "$1"
}

# --- build -------------------------------------------------------------------
# Turn the detected file list into a markdown comment body:
#   [MESSAGE, blank line]  (only when MESSAGE is non-empty)
#   ![<relpath>](<URL_PREFIX><percent-encoded relpath>)   x N
#   blank line
#   MARKER
build() {
  : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
  local url_prefix="${URL_PREFIX:-}"
  local message="${MESSAGE:-}"
  local marker="${MARKER:-}"

  local body="$RUNNER_TEMP/comment-body.md"
  : > "$body"

  # 1. Optional leading message.
  if [ -n "$message" ]; then
    printf '%s\n\n' "$message" >> "$body"
  fi

  # 2. One image per detected file. URL_PREFIX is expected to end with a slash,
  #    so the relative path is simply concatenated onto it.
  local rel encoded_rel alt_rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    encoded_rel=$(urlencode_path "$rel")
    alt_rel=$(escape_markdown_alt "$rel")
    printf '![%s](%s%s)\n' "$alt_rel" "$url_prefix" "$encoded_rel" >> "$body"
  done < "$RUNNER_TEMP/files.txt"

  # 3. Blank line then the hidden marker (used to find/replace prior comments).
  printf '\n%s\n' "$marker" >> "$body"

  # Also surface the body in the run's step summary (guarded for local runs).
  cat "$body" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

case "$MODE" in
  detect) detect ;;
  build)  build ;;
  *)
    echo "comment.sh: unknown mode '${MODE}' (expected detect|build)" >&2
    exit 1
    ;;
esac
