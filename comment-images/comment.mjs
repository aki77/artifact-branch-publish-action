#!/usr/bin/env node

// =============================================================================
// artifact-branch-comment-images
//
// Helper script for the comment-images composite action. Mode is selected by
// the first CLI argument. This script is env-driven and resolves relative
// paths against the current working directory (== GITHUB_WORKSPACE),
// mirroring the style of publish.sh.
//
// Modes:
//   detect  - expand FILES globs, produce a relative-path list + matched flag
//   build   - turn the detected file list into a markdown comment body
// =============================================================================

import { writeFileSync, appendFileSync, readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

// --- helpers -----------------------------------------------------------------

// Fail fast with a clear message on unsupported Node. globSync was only added
// to node:fs (and stabilised) in Node 22; the action.yml steps invoke bare
// `node` off PATH without a setup-node step, so a runner whose default node is
// older would otherwise fail with an obscure error. Surface an explicit
// requirement instead.
//
// IMPORTANT: globSync is NOT statically imported (`import { globSync } from
// 'node:fs'`). A static named import is resolved during module linking, before
// any top-level or main() code runs, so on Node <22 it would throw
// `SyntaxError: ... does not provide an export named 'globSync'` and this guard
// would never get the chance to run. Instead globSync is pulled synchronously
// via createRequire inside getGlobSync(), which returns `undefined` (rather
// than throwing at link time) on old Node -- so assertNodeVersion() runs first
// and produces the clear message.
export const assertNodeVersion = (versionString = process.versions.node) => {
  const major = Number.parseInt(versionString.split('.')[0], 10);
  if (!Number.isFinite(major) || major < 22) {
    throw new Error(
      `comment.mjs: Node >=22 is required (found ${versionString}). ` +
        `Add an actions/setup-node step with node-version: 22 before this action.`,
    );
  }
};

// Synchronously resolve node:fs.globSync. On Node <22 the export is absent, so
// this returns undefined; callers reach here only after assertNodeVersion() has
// already thrown the clear requirement error, so that case is not hit in
// practice.
const nodeRequire = createRequire(import.meta.url);
const getGlobSync = () => nodeRequire('node:fs').globSync;

// Percent-encode a relative path for use inside a markdown link URL, one path
// segment at a time so the `/` separators stay intact. Needed because
// screenshot/E2E tooling commonly produces filenames with spaces, parentheses,
// or non-ASCII characters, which would otherwise break the `![alt](url)` link.
export const urlencodePath = (rel) =>
  rel.split('/').map(encodeURIComponent).join('/');

// Escape `[`, `]`, and `\` in a relative path so it can be safely used as the
// alt text of a markdown image link (`![<alt>](...)`). Unescaped `]` would
// otherwise close the alt text early and break the link.
export const escapeMarkdownAlt = (rel) => rel.replace(/[\\[\]]/g, '\\$&');

// --- detect --------------------------------------------------------------
// Expand the FILES globs into a stable, de-duplicated list of relative paths.
// Unlike publish.sh, zero matches is NOT an error here: the caller simply
// skips publishing/commenting when nothing matched.

// filesRaw is intentionally split on whitespace (not just newlines) so that
// multiple patterns separated by spaces expand independently -- this mirrors
// the unquoted `for f in $FILES` word-splitting of the original bash version,
// where the default IFS splits on both spaces and newlines. So `files:` may
// be written either way (or mixed).
//
// NOTE (absolute paths): if a pattern is an absolute path, fs.globSync
// returns absolute paths for it, which breaks the "relative path" contract
// documented above. FILES is expected to hold relative glob patterns; the
// bash version had the same limitation, so behaviour is unchanged.
//
// NOTE (non-existent literals): fs.globSync only returns entries that exist on
// disk, even for a pattern with no glob metacharacters. This differs from the
// bash version: there, an unquoted literal token with no glob chars (e.g.
// `shot.png`) was never subject to pathname expansion, so it passed through
// literally whether or not the file existed, and a missing file surfaced as a
// downstream publish failure. Here such a literal is silently dropped (and, if
// it was the only entry, `matched` becomes false). This is intentional: a
// pattern that matches nothing simply contributes nothing.
export const expandFiles = (filesRaw, cwd) => {
  const globSync = getGlobSync();
  const patterns = filesRaw.split(/\s+/).filter(Boolean);

  const matches = new Set();
  for (const pattern of patterns) {
    for (const match of globSync(pattern, { cwd })) {
      const rel = match.replace(/^\.\//, '');
      if (rel) matches.add(rel);
    }
  }

  return [...matches].sort();
};

export const requireEnv = (env, name) => {
  const value = env[name];
  if (value === undefined || value === '') {
    throw new Error(`comment.mjs: ${name} is required`);
  }
  return value;
};

export const detect = (env) => {
  const filesRaw = requireEnv(env, 'FILES');
  const runnerTemp = requireEnv(env, 'RUNNER_TEMP');
  const cwd = env.GITHUB_WORKSPACE ?? process.cwd();

  const list = expandFiles(filesRaw, cwd);
  const matched = list.length > 0 ? 'true' : 'false';

  // Write the file list (one relative path per line) where build can read
  // it. Empty $list must yield an empty file (no stray blank line).
  const filesTxt = list.length ? `${list.join('\n')}\n` : '';
  writeFileSync(path.join(runnerTemp, 'files.txt'), filesTxt);

  // GITHUB_OUTPUT may be absent (e.g. local runs) - guard so we never fail.
  if (env.GITHUB_OUTPUT) {
    appendFileSync(env.GITHUB_OUTPUT, `matched=${matched}\n`);
  }

  // Zero matches is a valid, non-error outcome.
};

// --- build -------------------------------------------------------------------
// Turn the detected file list into a markdown comment body:
//   [MESSAGE, blank line]  (only when MESSAGE is non-empty)
//   ![<relpath>](<URL_PREFIX><percent-encoded relpath>)   x N
//   blank line
//   MARKER

export const buildBody = ({ files, urlPrefix, message, marker }) => {
  let body = '';

  // 1. Optional leading message.
  if (message) body += `${message}\n\n`;

  // 2. One image per detected file. URL_PREFIX is expected to end with a
  //    slash, so the relative path is simply concatenated onto it.
  for (const rel of files) {
    body += `![${escapeMarkdownAlt(rel)}](${urlPrefix}${urlencodePath(rel)})\n`;
  }

  // 3. Blank line then the hidden marker (used to find/replace prior comments).
  body += `\n${marker}\n`;

  return body;
};

export const build = (env) => {
  const runnerTemp = requireEnv(env, 'RUNNER_TEMP');
  const urlPrefix = env.URL_PREFIX ?? '';
  const message = env.MESSAGE ?? '';
  const marker = env.MARKER ?? '';

  const filesTxtPath = path.join(runnerTemp, 'files.txt');
  const files = readFileSync(filesTxtPath, 'utf8')
    .split('\n')
    .filter((line) => line.length > 0);

  const body = buildBody({ files, urlPrefix, message, marker });

  writeFileSync(path.join(runnerTemp, 'comment-body.md'), body);

  // Also surface the body in the run's step summary (guarded for local runs).
  if (env.GITHUB_STEP_SUMMARY) {
    appendFileSync(env.GITHUB_STEP_SUMMARY, body);
  }
};

// --- entrypoint ----------------------------------------------------------

export const main = (argv, env) => {
  const mode = argv[2] ?? '';

  try {
    assertNodeVersion();
    switch (mode) {
      case 'detect':
        detect(env);
        break;
      case 'build':
        build(env);
        break;
      default:
        throw new Error(
          `comment.mjs: unknown mode '${mode}' (expected detect|build)`,
        );
    }
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }
};

// Run main() only when invoked as a CLI (not when imported by tests). Compare
// against pathToFileURL(...).href rather than a hand-built `file://` string so
// that paths containing spaces or other characters that require percent-encoding
// still match import.meta.url (which is always a normalized, encoded URL).
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv, process.env);
}
