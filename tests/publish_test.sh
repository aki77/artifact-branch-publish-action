#!/usr/bin/env bash
set -uo pipefail

# The git-wrapper helpers below (bq/rbq/pbq) are only ever called from inside
# check "..." strings via eval, which shellcheck cannot trace; hence the
# per-definition SC2329 (unused function) suppressions.

# =============================================================================
# Integration tests for publish.sh
#
# Uses a local bare repository (file:// injected via REPO_URL) as the remote,
# a dummy GITHUB_REPOSITORY, a temp GITHUB_OUTPUT file, and a dummy SERVER_URL.
# RETAIN_DAYS is kept small (7) for the tests.
#
# Rotation is age-based: the active generation is rotated once its OLDEST commit
# is older than RETAIN_DAYS. To exercise this deterministically the tests inject
# a fixed commit date into publish.sh via GIT_COMMITTER_DATE / GIT_AUTHOR_DATE,
# so a generation can be made to look "old" without waiting real days.
#
# Each check prints PASS/FAIL. A single failure makes the script exit non-zero.
# =============================================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PUBLISH="$HERE/../publish.sh"

# Scratchpad root (keep the project dir clean).
SCRATCH_ROOT="${SCRATCH_ROOT:-/private/tmp/claude-501/-Users-aki-src-github-com-aki77-artifact-branch-publish-action/3382d42c-7494-4af0-8420-72393229501f/scratchpad}"
mkdir -p "$SCRATCH_ROOT"
TMP="$(mktemp -d "$SCRATCH_ROOT/publish_test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BARE="$TMP/remote.git"
BRANCH="artifacts"
RETAIN=7

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1 (expr: $2)"; fi; }

# --- Setup -------------------------------------------------------------------
git init -q --bare "$BARE"

# bq: run git against the bare repo.
# shellcheck disable=SC2329
bq() { git --git-dir="$BARE" "$@"; }

# Run one publish. Args: <workspace-dir> <dest-dir> <files-glob> [commit-date]
# commit-date, when given, is injected as the commit's author/committer date
# (any format git accepts, e.g. "10 days ago" or an ISO timestamp) so the
# resulting commit can be made to look old for age-based rotation. When omitted
# the commit is dated "now".
# Sets global OUT_SHA, OUT_BRANCH, OUT_URL from the captured GITHUB_OUTPUT.
run_publish() {
  local ws="$1" dest="$2" files="$3" cdate="${4:-}"
  local out="$TMP/output.$RANDOM"
  local envv=(
    "REPO_URL=file://$BARE"
    "GITHUB_REPOSITORY=owner/repo"
    "GITHUB_OUTPUT=$out"
    "SERVER_URL=https://raw.example.test"
    "BRANCH_PREFIX=$BRANCH"
    "DEST_DIR=$dest"
    "RUN_ID=test-run"
    "RUN_ATTEMPT=1"
    "RETAIN_DAYS=$RETAIN"
    "FILES=$files"
    "GITHUB_TOKEN=dummy"
  )
  if [ -n "$cdate" ]; then
    envv+=("GIT_COMMITTER_DATE=$cdate" "GIT_AUTHOR_DATE=$cdate")
  fi
  ( cd "$ws" && env "${envv[@]}" bash "$PUBLISH" >/dev/null 2>"$TMP/err.log" )
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "  publish.sh exited $rc; stderr:" >&2
    sed 's/^/    /' "$TMP/err.log" >&2
    return $rc
  fi
  OUT_SHA="$(sed -n 's/^commit-sha=//p' "$out")"
  OUT_BRANCH="$(sed -n 's/^branch=//p' "$out")"
  OUT_URL="$(sed -n 's/^url-prefix=//p' "$out")"
  return 0
}

# Build a workspace with an artifact file at a given relative path.
make_ws() {
  local name="$1" relpath="$2"
  local ws="$TMP/ws-$name"
  mkdir -p "$ws/$(dirname "$relpath")"
  echo "content-$name" > "$ws/$relpath"
  echo "$ws"
}

# days_ago <n>: a git "raw" date (@<epoch> +0000) for <n> days before now.
# Using an absolute epoch keeps this portable across BSD/GNU git date parsing,
# where relative strings like "10 days ago" are not accepted as commit dates.
NOW="$(date +%s)"
days_ago() { printf '@%d +0000' "$(( NOW - $1 * 86400 ))"; }

# A commit date safely older than RETAIN_DAYS, used to age a generation out.
OLD_DATE="$(days_ago $(( RETAIN + 3 )))"

# =============================================================================
echo "== Test 1: first run creates orphan <branch-prefix>-gen-0 =="
# Date this first commit OLD so gen-0's oldest commit is already past the
# retention window; later pushes will then rotate off it.
WS="$(make_ws first artifacts/a.gif)"
run_publish "$WS" "pr-1" "artifacts/a.gif" "$OLD_DATE" || fail "publish (first run) succeeded"
check "gen-0 exists after first run" "bq show-ref --verify --quiet refs/heads/${BRANCH}-gen-0"
check "first run branch output is gen-0" "[ '$OUT_BRANCH' = '${BRANCH}-gen-0' ]"
check "gen-0 has exactly 1 commit" "[ \"\$(bq rev-list --count ${BRANCH}-gen-0)\" -eq 1 ]"
SHA0="$OUT_SHA"

echo
echo "== Test 7: url-prefix format =="
check "url-prefix matches expected format" \
  "printf '%s' '$OUT_URL' | grep -Eq '^https://raw\\.example\\.test/owner/repo/[0-9a-f]{40}/pr-1/\$'"

echo
echo "== Test 2: a recent generation stays active (no rotation) =="
# Fresh remote so gen-0's oldest commit is "now"; subsequent pushes append.
RECENT_BARE="$TMP/remote-recent.git"
git init -q --bare "$RECENT_BARE"
recent_publish() {
  local ws="$1" dest="$2" files="$3" cdate="${4:-}"
  local out="$TMP/output.$RANDOM"
  local envv=(
    "REPO_URL=file://$RECENT_BARE"
    "GITHUB_REPOSITORY=owner/repo" "GITHUB_OUTPUT=$out"
    "SERVER_URL=https://raw.example.test" "BRANCH_PREFIX=$BRANCH"
    "DEST_DIR=$dest" "RUN_ID=test-run" "RUN_ATTEMPT=1"
    "RETAIN_DAYS=$RETAIN" "FILES=$files" "GITHUB_TOKEN=dummy"
  )
  if [ -n "$cdate" ]; then
    envv+=("GIT_COMMITTER_DATE=$cdate" "GIT_AUTHOR_DATE=$cdate")
  fi
  ( cd "$ws" && env "${envv[@]}" bash "$PUBLISH" >/dev/null 2>"$TMP/err.log" ) \
    || { sed 's/^/    /' "$TMP/err.log" >&2; return 1; }
  RC_BRANCH="$(sed -n 's/^branch=//p' "$out")"
  RC_SHA="$(sed -n 's/^commit-sha=//p' "$out")"
}
# shellcheck disable=SC2329
rbq() { git --git-dir="$RECENT_BARE" "$@"; }

WS_R1="$(make_ws recentA artifacts/a.gif)"
recent_publish "$WS_R1" "pr-a" "artifacts/a.gif" || fail "recent publish A succeeded"
RECENT_SHA0="$RC_SHA"
check "recent run 1 on gen-0" "[ '$RC_BRANCH' = '${BRANCH}-gen-0' ]"

WS_R2="$(make_ws recentB artifacts/b.gif)"
recent_publish "$WS_R2" "pr-b" "artifacts/b.gif" || fail "recent publish B succeeded"
check "recent run 2 stays on gen-0 (recent, no rotation)" "[ '$RC_BRANCH' = '${BRANCH}-gen-0' ]"
check "gen-0 has 2 commits" "[ \"\$(rbq rev-list --count ${BRANCH}-gen-0)\" -eq 2 ]"
check "first recent SHA still reachable" "rbq cat-file -e '$RECENT_SHA0'"

echo
echo "== Test 3: an aged-out generation rotates to the next generation =="
# Back on the main BARE: gen-0's oldest commit is OLD_DATE (from Test 1), which
# is older than RETAIN_DAYS, so the next push must rotate to gen-1.
WS_ROT="$(make_ws rot artifacts/rot.gif)"
run_publish "$WS_ROT" "pr-rot" "artifacts/rot.gif" || fail "publish (rotation) succeeded"
check "aged generation rotated to gen-1" "[ '$OUT_BRANCH' = '${BRANCH}-gen-1' ]"
check "gen-1 exists after rotation" "bq show-ref --verify --quiet refs/heads/${BRANCH}-gen-1"
check "gen-1 holds only 1 commit (fresh orphan)" "[ \"\$(bq rev-list --count ${BRANCH}-gen-1)\" -eq 1 ]"

echo
echo "== Test 8: subdirectory structure is preserved =="
WS_SUB="$(mktemp -d "$TMP/ws-sub.XXXXXX")"
mkdir -p "$WS_SUB/sub/a"
echo "deep" > "$WS_SUB/sub/a/x.gif"
# gen-1 is fresh (dated now), so this appends without rotating.
run_publish "$WS_SUB" "pr-sub" "sub/a/x.gif" || fail "publish (subdir) succeeded"
check "subdir push stays on gen-1" "[ '$OUT_BRANCH' = '${BRANCH}-gen-1' ]"
check "subdir file placed at pr-sub/sub/a/x.gif in gen ${OUT_BRANCH}" \
  "bq cat-file -e '${OUT_BRANCH}:pr-sub/sub/a/x.gif'"

echo
echo "== Test 6: a returned SHA survives while its generation is kept =="
# SHA0 (gen-0) is still kept because gen-0 and gen-1 are the two newest gens.
check "first SHA reachable while gen-0 is still one of the two newest" "bq cat-file -e '$SHA0'"
check "first SHA reachable from gen-0 tip" \
  "[ -n \"\$(bq branch --contains '$SHA0' --list '${BRANCH}-gen-0' 2>/dev/null)\" ] || bq merge-base --is-ancestor '$SHA0' ${BRANCH}-gen-0"

echo
echo "== Drive two rotations to exercise old-generation pruning =="
# Use a dedicated remote and inject old commit dates so each generation is born
# already aged, forcing the next push to rotate. This walks gen-0 -> gen-1 ->
# gen-2, at which point the oldest (gen-0) must be pruned.
PRUNE_BARE="$TMP/remote-prune.git"
git init -q --bare "$PRUNE_BARE"
pbq() { git --git-dir="$PRUNE_BARE" "$@"; }
prune_publish() {
  local ws="$1" dest="$2" files="$3" cdate="${4:-}"
  local out="$TMP/output.$RANDOM"
  local envv=(
    "REPO_URL=file://$PRUNE_BARE"
    "GITHUB_REPOSITORY=owner/repo" "GITHUB_OUTPUT=$out"
    "SERVER_URL=https://raw.example.test" "BRANCH_PREFIX=$BRANCH"
    "DEST_DIR=$dest" "RUN_ID=test-run" "RUN_ATTEMPT=1"
    "RETAIN_DAYS=$RETAIN" "FILES=$files" "GITHUB_TOKEN=dummy"
  )
  if [ -n "$cdate" ]; then
    envv+=("GIT_COMMITTER_DATE=$cdate" "GIT_AUTHOR_DATE=$cdate")
  fi
  ( cd "$ws" && env "${envv[@]}" bash "$PUBLISH" >/dev/null 2>"$TMP/err.log" ) \
    || { sed 's/^/    /' "$TMP/err.log" >&2; return 1; }
  PB_BRANCH="$(sed -n 's/^branch=//p' "$out")"
  PB_SHA="$(sed -n 's/^commit-sha=//p' "$out")"
}
pgen_branches() { pbq for-each-ref --format='%(refname:short)' "refs/heads/${BRANCH}-gen-*" | sort -V; }

VERY_OLD="$(days_ago $(( RETAIN * 3 )))"
OLDISH="$(days_ago $(( RETAIN * 2 )))"

# gen-0: oldest commit VERY_OLD -> next push rotates.
W="$(make_ws p0 artifacts/p0.gif)"
prune_publish "$W" "pr-p0" "artifacts/p0.gif" "$VERY_OLD" || fail "prune publish p0 succeeded"
PRUNE_SHA0="$PB_SHA"
check "prune: start on gen-0" "[ '$PB_BRANCH' = '${BRANCH}-gen-0' ]"

# rotate to gen-1, dated OLDISH (still older than RETAIN) so it too can age out.
W="$(make_ws p1 artifacts/p1.gif)"
prune_publish "$W" "pr-p1" "artifacts/p1.gif" "$OLDISH" || fail "prune publish p1 succeeded"
check "prune: rotated to gen-1" "[ '$PB_BRANCH' = '${BRANCH}-gen-1' ]"

# gen-1's oldest is OLDISH (> RETAIN) -> next push rotates to gen-2 and prunes gen-0.
W="$(make_ws p2 artifacts/p2.gif)"
prune_publish "$W" "pr-p2" "artifacts/p2.gif" || fail "prune publish p2 succeeded"
check "prune: rotated to gen-2" "[ '$PB_BRANCH' = '${BRANCH}-gen-2' ]"

echo
echo "== Test 4: only the newest two generations remain =="
REMAINING="$(pgen_branches | tr '\n' ' ')"
echo "  remaining generations: $REMAINING"
check "gen-0 was pruned" "! pbq show-ref --verify --quiet refs/heads/${BRANCH}-gen-0"
check "gen-1 still present" "pbq show-ref --verify --quiet refs/heads/${BRANCH}-gen-1"
check "gen-2 still present" "pbq show-ref --verify --quiet refs/heads/${BRANCH}-gen-2"
check "exactly two generations remain" "[ \"\$(pgen_branches | wc -l | tr -d ' ')\" -eq 2 ]"

echo
echo "== Test 5: a pruned generation's head SHA is unreachable =="
if pbq cat-file -e "$PRUNE_SHA0" 2>/dev/null; then
  CONTAINED="$(pbq branch --contains "$PRUNE_SHA0" 2>/dev/null | tr -d ' \n')"
  check "pruned SHA not contained in any branch" "[ -z '$CONTAINED' ]"
else
  pass "pruned SHA object no longer present (fully unreachable)"
fi

echo
echo "== Confirm gc makes the pruned object unreachable =="
pbq reflog expire --expire=now --all >/dev/null 2>&1 || true
pbq gc --prune=now >/dev/null 2>&1 || true
check "after gc, pruned SHA is gone" "! pbq cat-file -e '$PRUNE_SHA0' 2>/dev/null"

echo
echo "== Test 9: DEST_DIR defaults to RUN_ID-RUN_ATTEMPT when unset =="
# Use an independent bare repo so this doesn't perturb the generations above.
BARE_AUTO="$TMP/remote-auto.git"
git init -q --bare "$BARE_AUTO"
WS_AUTO="$(make_ws auto artifacts/auto.gif)"
OUT_AUTO="$TMP/output.auto"
( cd "$WS_AUTO" && \
  REPO_URL="file://$BARE_AUTO" \
  GITHUB_REPOSITORY="owner/repo" \
  GITHUB_OUTPUT="$OUT_AUTO" \
  SERVER_URL="https://raw.example.test" \
  BRANCH_PREFIX="$BRANCH" \
  RUN_ID="99887766" \
  RUN_ATTEMPT="2" \
  RETAIN_DAYS="$RETAIN" \
  FILES="artifacts/auto.gif" \
  GITHUB_TOKEN="dummy" \
  bash "$PUBLISH" >/dev/null 2>"$TMP/err.log" ) || fail "publish (auto dest-dir) succeeded"
AUTO_URL="$(sed -n 's/^url-prefix=//p' "$OUT_AUTO")"
AUTO_BRANCH="$(sed -n 's/^branch=//p' "$OUT_AUTO")"
check "auto dest-dir url ends in /99887766-2/" \
  "printf '%s' '$AUTO_URL' | grep -Eq '/99887766-2/\$'"
check "auto dest-dir file placed under 99887766-2/" \
  "git --git-dir='$BARE_AUTO' cat-file -e '${AUTO_BRANCH}:99887766-2/artifacts/auto.gif'"

echo
echo "============================================================"
if [ "$FAILURES" -eq 0 ]; then
  echo "ALL CHECKS PASSED"
  exit 0
else
  echo "$FAILURES CHECK(S) FAILED"
  exit 1
fi
