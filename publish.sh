#!/usr/bin/env bash
set -euo pipefail
# globstar: expand `**` recursively so patterns like `artifacts/**/*.txt` match
#   files at any depth (including directly under artifacts/), matching how users
#   expect glob patterns in `files:` to behave. Only present on bash 4+, so it
#   is enabled best-effort (GitHub's runners ship bash 5).
# nullglob: a pattern matching nothing expands to nothing rather than being
#   passed through literally (which would make rsync fail on a bogus path).
shopt -s globstar 2>/dev/null || true
shopt -s nullglob

# =============================================================================
# artifact-branch-publish
#
# Publishes files to a dedicated rotating branch (<branch-prefix>-gen-N) in the
# repository and returns a commit-pinned raw URL prefix.
#
# Strategy: two-branch generation rotation, rotated by age.
#   - Files are appended as new commits to the active generation branch.
#   - When the active generation's oldest commit becomes older than RETAIN_DAYS,
#     a new orphan generation is started (holding only the current commit).
#   - Only the two most recent generations are kept on the remote; older ones
#     are deleted after a successful push.
#
# The returned commit SHA is fixed at commit time and never changes (commits
# are append-only). Because two generations are always kept and a generation is
# only retired once it is older than RETAIN_DAYS, every returned URL stays valid
# for at least RETAIN_DAYS.
#
# The current working directory's .git is NEVER touched: all git operations
# happen inside a fresh mktemp -d clone.
# =============================================================================

# --- Environment ------------------------------------------------------------
# Required from action.yml env:
#   FILES, BRANCH_PREFIX, RETAIN_DAYS, GITHUB_TOKEN
# Provided by GitHub Actions:
#   GITHUB_REPOSITORY, GITHUB_OUTPUT, RUN_ID, RUN_ATTEMPT
# Overridable for testability:
#   REPO_URL   - remote git URL (default built from token + repository)
#   SERVER_URL - github.com host used to build the file URLs (default
#                https://github.com). Each URL is assembled as
#                $SERVER_URL/$repo/blob/$sha/$path?raw=true, which serves the
#                raw bytes from the same origin as github.com.
#   ACTION_PATH - directory of this action's checkout (passed from action.yml as
#                github.action_path); used to locate comment-files/comment.mjs
#                for URL encoding. Falls back to this script's own directory.
#   GITHUB_OUTPUT - output file (GitHub sets this; tests inject a temp file)
#   DEST_DIR   - subdirectory to publish under (default derived from RUN_ID/RUN_ATTEMPT)

: "${FILES:?FILES is required}"
# Derive a per-run subdirectory so every invocation lands in its own directory,
# both on the branch (easy to inspect) and in the returned URL. RUN_ID is unique
# per workflow run and RUN_ATTEMPT disambiguates re-runs. DEST_DIR may still be
# overridden directly (used by tests).
: "${RUN_ID:?RUN_ID is required}"
: "${RUN_ATTEMPT:?RUN_ATTEMPT is required}"
DEST_DIR="${DEST_DIR:-${RUN_ID}-${RUN_ATTEMPT}}"
# Normalise DEST_DIR once here (strip leading/trailing slashes) so both the
# copy destination and the URL prefix share the same canonical value.
DEST_DIR="${DEST_DIR#/}"
DEST_DIR="${DEST_DIR%/}"
BRANCH_PREFIX="${BRANCH_PREFIX:-artifacts}"
RETAIN_DAYS="${RETAIN_DAYS:-30}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
SERVER_URL="${SERVER_URL:-https://github.com}"
# Locate the action checkout so we can reuse comment-files/comment.mjs for URL
# encoding. action.yml passes github.action_path; fall back to this script's dir.
ACTION_PATH="${ACTION_PATH:-$(dirname "$0")}"

if [ -z "${REPO_URL:-}" ]; then
  REPO_URL="https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

# Directory publish.sh was launched from (== GITHUB_WORKSPACE). rsync source
# must be resolved relative to this, so capture it before any cd.
SOURCE_DIR="$PWD"

# git author identity (bot) applied per-command via -c to avoid touching config.
GIT_ID=(-c "user.name=github-actions[bot]" -c "user.email=41898282+github-actions[bot]@users.noreply.github.com")

# Results carried out of run_once for final output.
RESULT_SHA=""
RESULT_BRANCH=""
# Newline-separated list of published relative paths (DEST_DIR excluded), set by
# copy_files and consumed when assembling the `urls` output.
RESULT_FILES=""

# --- Helpers ----------------------------------------------------------------

# gen_branch <n>: the branch name for generation <n>. Single source of truth for
# the naming scheme, kept in sync with the extraction pattern in list_gens.
gen_branch() {
  echo "${BRANCH_PREFIX}-gen-$1"
}

# list_gens: print every existing generation number (one per line, unsorted).
list_gens() {
  git ls-remote --heads "$REPO_URL" "$(gen_branch '*')" 2>/dev/null \
    | sed -n "s#.*refs/heads/$(gen_branch '\([0-9][0-9]*\)')\$#\1#p"
}

# start_orphan_gen <workdir> <n>: begin generation <n> as an empty orphan
# branch, dropping any prior history/work tree.
start_orphan_gen() {
  local workdir="$1" n="$2"
  git -C "$workdir" checkout -q --orphan "$(gen_branch "$n")"
  git -C "$workdir" rm -rf . >/dev/null 2>&1 || true
}

# find_active_gen: print the highest existing generation number, or empty if none.
find_active_gen() {
  local gens
  gens="$(list_gens)"
  if [ -z "$gens" ]; then
    return 0
  fi
  printf '%s\n' "$gens" | sort -n | tail -n 1
}

# oldest_commit_epoch <workdir>: committer date (Unix epoch) of the active
# generation's oldest commit. Requires a full clone (see run_once).
oldest_commit_epoch() {
  git -C "$1" log --max-parents=0 --format=%ct -1 HEAD
}

# should_rotate <oldest_commit_epoch>: succeeds when the active generation's
# oldest commit is older than RETAIN_DAYS, i.e. the generation has aged out.
should_rotate() {
  local oldest="$1" now cutoff
  now="$(date +%s)"
  cutoff="$((now - RETAIN_DAYS * 86400))"
  [ "$oldest" -lt "$cutoff" ]
}

# copy_files: copy $FILES (space-separated globs, relative paths preserved via
# -R) from SOURCE_DIR into the destination subdir of the given work tree.
# Args: <workdir>
copy_files() {
  local workdir="$1"
  mkdir -p "$workdir/$DEST_DIR"
  # Expand $FILES from SOURCE_DIR (so relative globs resolve against the
  # workspace) into an explicit list. globstar/nullglob make `**` recurse and
  # non-matching patterns vanish, so `matches` holds exactly the real files.
  # Promoted to the global RESULT_FILES (not `local`) so the final output block
  # can turn these DEST_DIR-relative paths into per-file URLs.
  # $FILES intentionally unquoted to allow multiple space-separated globs.
  # shellcheck disable=SC2086
  matches=$(cd "$SOURCE_DIR" && for f in $FILES; do printf '%s\n' "$f"; done)
  if [ -z "$matches" ]; then
    echo "artifact-branch-publish: no files matched pattern(s): ${FILES}" >&2
    return 1
  fi
  RESULT_FILES="$matches"
  # Run rsync from SOURCE_DIR so -R preserves the relative structure.
  ( cd "$SOURCE_DIR" && printf '%s\n' "$matches" | rsync -R --files-from=- ./ "$workdir/$DEST_DIR/" )
}

# commit_all: stage everything and commit inside the given work tree.
# Args: <workdir> <message>
commit_all() {
  local workdir="$1" msg="$2"
  git -C "$workdir" "${GIT_ID[@]}" add -A
  git -C "$workdir" "${GIT_ID[@]}" commit -m "$msg"
}

# --- Core -------------------------------------------------------------------

# run_once: perform one full publish attempt. Builds a fresh work tree, so it
# can be safely retried on push conflict.
run_once() {
  local workdir
  workdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$workdir'" RETURN

  local n
  n="$(find_active_gen)"

  local target_gen target_branch rotated="false"
  if [ -z "$n" ]; then
    # No generation exists yet. Clone whatever is there (may be empty) and
    # start an orphan gen-0.
    n=0
    target_gen=0
    if ! git clone --depth=1 "$REPO_URL" "$workdir" 2>/dev/null; then
      # Completely empty remote (no default branch): initialise locally.
      git init -q "$workdir"
      git -C "$workdir" remote add origin "$REPO_URL" 2>/dev/null || true
    fi
    start_orphan_gen "$workdir" 0
  else
    # Clone the active generation in full: rotation is decided from its OLDEST
    # commit's date, so the whole history of the generation must be present
    # (a shallow clone could miss the oldest commit).
    git clone --single-branch \
      --branch "$(gen_branch "$n")" "$REPO_URL" "$workdir"

    # Decide rotation from the age of the active generation's oldest commit:
    # once that commit is older than RETAIN_DAYS the generation has aged out,
    # and this push starts a fresh orphan generation instead of appending.
    local oldest_epoch
    oldest_epoch="$(oldest_commit_epoch "$workdir")"
    if should_rotate "$oldest_epoch"; then
      rotated="true"
      target_gen="$((n + 1))"
      # Start a brand-new orphan generation holding only this push's commit
      # (old history is intentionally dropped).
      start_orphan_gen "$workdir" "$target_gen"
    else
      target_gen="$n"
    fi
  fi
  target_branch="$(gen_branch "$target_gen")"

  # Append the artifacts and commit.
  copy_files "$workdir"
  commit_all "$workdir" "Publish artifacts: ${DEST_DIR}"

  # SHA is finalised now and never changes (append-only).
  local sha
  sha="$(git -C "$workdir" rev-parse HEAD)"

  # Push (force). A conflicting concurrent push makes this fail and the outer
  # retry loop re-runs run_once from scratch.
  if ! git -C "$workdir" push -f "$REPO_URL" "HEAD:${target_branch}"; then
    return 1
  fi

  # Only after a successful push, prune generations older than the two newest.
  if [ "$rotated" = "true" ]; then
    local keep_floor k
    keep_floor="$((target_gen - 1))"
    while IFS= read -r k; do
      [ -z "$k" ] && continue
      if [ "$k" -lt "$keep_floor" ]; then
        git -C "$workdir" push "$REPO_URL" --delete "$(gen_branch "$k")" 2>/dev/null || true
      fi
    done < <(list_gens)
  fi

  RESULT_SHA="$sha"
  RESULT_BRANCH="$target_branch"
  return 0
}

# --- Main -------------------------------------------------------------------

main() {
  # Retry a few times with a short linear backoff: run_once only fails on a
  # losing force-push race against a concurrent job, which clears quickly.
  local i ok="false"
  for i in 1 2 3; do
    if run_once; then
      ok="true"
      break
    fi
    sleep "$((i * 3))"
  done

  if [ "$ok" != "true" ]; then
    echo "artifact-branch-publish: failed to publish after 3 attempts" >&2
    return 1
  fi

  # DEST_DIR was normalised at startup, so the path joins cleanly. `base` is the
  # commit-pinned, same-origin prefix all file URLs are anchored to; comment.mjs
  # assembles the identical string for the comment body, so keep the two in sync.
  local base="${SERVER_URL}/${GITHUB_REPOSITORY}/blob/${RESULT_SHA}/${DEST_DIR}"

  # Delegate the full URL construction to comment.mjs's buildFileUrl so the URL
  # format (segment-wise percent-encoding, the `blob/…?raw=true` shape) lives in
  # exactly one place and the standalone `urls` output matches the comment body.
  # RESULT_FILES holds DEST_DIR-relative paths and base already includes
  # DEST_DIR, so we must NOT prepend DEST_DIR again here.
  local urls
  urls="$(BASE="$base" RELS="$RESULT_FILES" MJS="${ACTION_PATH}/comment-files/comment.mjs" node --input-type=module -e '
    const { buildFileUrl } = await import(process.env.MJS);
    const base = process.env.BASE;
    const rels = process.env.RELS.split("\n").filter(Boolean);
    process.stdout.write(rels.map((r) => buildFileUrl(base, r)).join("\n"));
  ')"

  # `urls` is multi-line, so write it with the heredoc delimiter syntax GitHub
  # Actions supports for multi-line output values.
  {
    echo "commit-sha=${RESULT_SHA}"
    echo "branch=${RESULT_BRANCH}"
    echo "urls<<__ARTIFACT_URLS_EOF__"
    echo "${urls}"
    echo "__ARTIFACT_URLS_EOF__"
  } >> "${GITHUB_OUTPUT}"

  echo "Published to ${RESULT_BRANCH} @ ${RESULT_SHA}"
  echo "URLs:"
  echo "${urls}"
}

main "$@"
