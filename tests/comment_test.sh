#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Unit tests for comment-images/comment.sh
#
# These tests exercise comment.sh directly (no GitHub / gh dependency). All
# GitHub-provided env (GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, RUNNER_TEMP) is
# redirected into a temp dir. Each check prints PASS/FAIL; a single failure
# makes the script exit non-zero.
# =============================================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMENT="$HERE/../comment-images/comment.sh"

# Scratchpad root (keep the project dir clean).
SCRATCH_ROOT="${SCRATCH_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$SCRATCH_ROOT"
TMP="$(mktemp -d "$SCRATCH_ROOT/comment_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (expr: $2)"; fi; }

# run_detect <workspace-dir> <files> : run detect mode, capturing outputs.
# Sets DET_MATCHED (from GITHUB_OUTPUT) and populates $RT/files.txt.
run_detect() {
  local ws="$1" files="$2"
  RT="$TMP/rt.$RANDOM"
  mkdir -p "$RT"
  GO="$RT/github_output"
  : > "$GO"
  ( cd "$ws" && env \
      FILES="$files" \
      RUNNER_TEMP="$RT" \
      GITHUB_OUTPUT="$GO" \
      bash "$COMMENT" detect >"$RT/stdout" 2>"$RT/stderr" )
  DET_RC=$?
  DET_MATCHED="$(sed -n 's/^matched=//p' "$GO")"
  return 0
}

# =============================================================================
echo "== detect: space-separated globs expand =="
WS1="$TMP/ws1"
mkdir -p "$WS1/artifacts"
echo x > "$WS1/artifacts/a.gif"
echo x > "$WS1/artifacts/b.gif"
echo x > "$WS1/other.png"
run_detect "$WS1" "artifacts/*.gif other.png"
check "detect exits 0" "[ $DET_RC -eq 0 ]"
check "detect matched=true" "[ '$DET_MATCHED' = 'true' ]"
check "files.txt has a.gif" "grep -qx 'artifacts/a.gif' '$RT/files.txt'"
check "files.txt has b.gif" "grep -qx 'artifacts/b.gif' '$RT/files.txt'"
check "files.txt has other.png" "grep -qx 'other.png' '$RT/files.txt'"
check "files.txt has 3 lines" "[ \"\$(wc -l < '$RT/files.txt' | tr -d ' ')\" -eq 3 ]"

echo
echo "== detect: newline-separated globs expand =="
WS2="$TMP/ws2"
mkdir -p "$WS2/artifacts"
echo x > "$WS2/artifacts/a.gif"
echo x > "$WS2/artifacts/b.gif"
run_detect "$WS2" $'artifacts/a.gif\nartifacts/b.gif'
check "detect (newline) matched=true" "[ '$DET_MATCHED' = 'true' ]"
check "files.txt (newline) has a.gif" "grep -qx 'artifacts/a.gif' '$RT/files.txt'"
check "files.txt (newline) has b.gif" "grep -qx 'artifacts/b.gif' '$RT/files.txt'"

echo
echo "== detect: ** recursive match =="
# globstar (`**` recursion) requires bash 4+. GitHub's runners ship bash 5, but
# macOS ships bash 3.2 where `**` degrades to a single `*`. Only assert the
# recursive behaviour when the running bash actually supports globstar.
if ( shopt -s globstar 2>/dev/null ); then
  WS3="$TMP/ws3"
  mkdir -p "$WS3/artifacts/deep/nested"
  echo x > "$WS3/artifacts/top.gif"
  echo x > "$WS3/artifacts/deep/nested/low.gif"
  run_detect "$WS3" "artifacts/**/*.gif"
  check "detect (**) matched=true" "[ '$DET_MATCHED' = 'true' ]"
  check "files.txt (**) has top.gif" "grep -qx 'artifacts/top.gif' '$RT/files.txt'"
  check "files.txt (**) has nested low.gif" "grep -qx 'artifacts/deep/nested/low.gif' '$RT/files.txt'"
else
  echo "SKIP: globstar unsupported by this bash ($(bash --version | head -1)); ** recursion not asserted"
fi

echo
echo "== detect: nullglob - zero matches is not an error =="
WS4="$TMP/ws4"
mkdir -p "$WS4"
run_detect "$WS4" "artifacts/*.nope"
check "detect (no match) exits 0" "[ $DET_RC -eq 0 ]"
check "detect (no match) matched=false" "[ '$DET_MATCHED' = 'false' ]"
check "detect (no match) no stderr error" "[ ! -s '$RT/stderr' ]"
check "detect (no match) files.txt empty" "[ ! -s '$RT/files.txt' ]"

echo
echo "== detect: paths are ./-stripped and sorted/unique =="
WS5="$TMP/ws5"
mkdir -p "$WS5/artifacts"
echo x > "$WS5/artifacts/z.gif"
echo x > "$WS5/artifacts/a.gif"
# The same file referenced twice (via two patterns) must be de-duplicated,
# and leading ./ must be stripped.
run_detect "$WS5" "./artifacts/z.gif ./artifacts/a.gif artifacts/z.gif"
check "detect (dedupe) 2 lines" "[ \"\$(wc -l < '$RT/files.txt' | tr -d ' ')\" -eq 2 ]"
check "detect (dedupe) no ./ prefix" "! grep -q '^\\./' '$RT/files.txt'"
check "detect (sorted) a.gif before z.gif" \
  "[ \"\$(head -n1 '$RT/files.txt')\" = 'artifacts/a.gif' ]"

# --- build helper ------------------------------------------------------------
# run_build <files-list-lines> <message> <marker> <url_prefix>
# Writes files.txt from the given newline list, then runs build.
run_build() {
  local list="$1" message="$2" marker="$3" prefix="$4"
  BRT="$TMP/brt.$RANDOM"
  mkdir -p "$BRT"
  printf '%s\n' "$list" | sed '/^$/d' > "$BRT/files.txt"
  SUMMARY="$BRT/step_summary"
  : > "$SUMMARY"
  ( cd "$BRT" && env \
      RUNNER_TEMP="$BRT" \
      URL_PREFIX="$prefix" \
      MESSAGE="$message" \
      MARKER="$marker" \
      GITHUB_STEP_SUMMARY="$SUMMARY" \
      bash "$COMMENT" build )
  BUILD_RC=$?
  BODY="$BRT/comment-body.md"
  return 0
}

echo
echo "== build: image lines with trailing-slash prefix concat =="
run_build "artifacts/a.gif" "" "<!-- m -->" "https://raw.example.test/owner/repo/deadbeef/pr-1/"
check "build exits 0" "[ $BUILD_RC -eq 0 ]"
check "build image line correct" \
  "grep -qxF '![artifacts/a.gif](https://raw.example.test/owner/repo/deadbeef/pr-1/artifacts/a.gif)' '$BODY'"

echo
echo "== build: MESSAGE present at top =="
run_build "artifacts/a.gif" "Here are the screenshots" "<!-- m -->" "https://x/"
check "build first line is message" \
  "[ \"\$(head -n1 '$BODY')\" = 'Here are the screenshots' ]"
check "build second line is blank" \
  "[ -z \"\$(sed -n '2p' '$BODY')\" ]"

echo
echo "== build: MESSAGE empty => no message line =="
run_build "artifacts/a.gif" "" "<!-- m -->" "https://x/"
check "build first line is the image (no message)" \
  "printf '%s' \"\$(head -n1 '$BODY')\" | grep -q '^!\\[artifacts/a.gif\\]'"

echo
echo "== build: MARKER is the last line and matches input =="
MK="<!-- artifact-branch-comment-images -->"
run_build "artifacts/a.gif" "" "$MK" "https://x/"
check "build last line equals marker" \
  "[ \"\$(tail -n1 '$BODY')\" = '$MK' ]"

echo
echo "== build: subdirectory relpath preserved in alt text =="
run_build "a/b/c.gif" "" "<!-- m -->" "https://host/base/"
check "build subdir alt preserved" \
  "grep -qF '![a/b/c.gif](https://host/base/a/b/c.gif)' '$BODY'"

echo
echo "== build: multiple files each get a line =="
run_build $'artifacts/a.gif\nartifacts/b.gif' "" "<!-- m -->" "https://h/"
check "build has a.gif line" "grep -qF '![artifacts/a.gif](https://h/artifacts/a.gif)' '$BODY'"
check "build has b.gif line" "grep -qF '![artifacts/b.gif](https://h/artifacts/b.gif)' '$BODY'"

echo
echo "== build: body written to both comment-body.md and step summary =="
run_build "artifacts/a.gif" "Hello" "<!-- m -->" "https://h/"
check "comment-body.md non-empty" "[ -s '$BODY' ]"
check "step summary got the body" "grep -qF '![artifacts/a.gif](https://h/artifacts/a.gif)' '$SUMMARY'"
check "step summary got the message" "grep -qxF 'Hello' '$SUMMARY'"

echo
echo "============================================================"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "$FAILURES CHECK(S) FAILED"
  exit 1
fi
