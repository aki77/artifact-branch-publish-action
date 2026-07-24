import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  expandFiles,
  buildBody,
  detect,
  build,
  isImagePath,
} from '../comment-files/comment.mjs';

const TMP = mkdtempSync(path.join(tmpdir(), 'comment-test-'));
after(() => rmSync(TMP, { recursive: true, force: true }));

const scriptPath = fileURLToPath(
  new URL('../comment-files/comment.mjs', import.meta.url),
);

// Create a workspace dir under TMP populated with the given files. `files` maps
// a relative path to its contents; parent dirs are created as needed.
const makeWorkspace = (name, files) => {
  const ws = path.join(TMP, name);
  mkdirSync(ws, { recursive: true });
  for (const [rel, contents] of Object.entries(files)) {
    const full = path.join(ws, rel);
    mkdirSync(path.dirname(full), { recursive: true });
    writeFileSync(full, contents);
  }
  return ws;
};

// Create a RUNNER_TEMP dir under TMP with an empty GITHUB_OUTPUT file, returning
// both paths. Mirrors how the detect step is wired in the composite action.
const makeRunnerTemp = (name) => {
  const rt = path.join(TMP, name);
  mkdirSync(rt, { recursive: true });
  const githubOutput = path.join(rt, 'github_output');
  writeFileSync(githubOutput, '');
  return { rt, githubOutput };
};

// =============================================================================
// detect / expandFiles
// =============================================================================

test('detect: space-separated globs expand', () => {
  const ws = makeWorkspace('ws1', {
    'artifacts/a.gif': 'x',
    'artifacts/b.gif': 'x',
    'other.png': 'x',
  });

  const list = expandFiles('artifacts/*.gif other.png', ws);
  assert.deepEqual(list, ['artifacts/a.gif', 'artifacts/b.gif', 'other.png']);

  // Also exercise detect(env) end-to-end (files.txt + GITHUB_OUTPUT).
  const { rt, githubOutput } = makeRunnerTemp('rt1');

  detect({
    FILES: 'artifacts/*.gif other.png',
    RUNNER_TEMP: rt,
    GITHUB_OUTPUT: githubOutput,
    GITHUB_WORKSPACE: ws,
  });

  const filesTxt = readFileSync(path.join(rt, 'files.txt'), 'utf8');
  const lines = filesTxt.split('\n').filter(Boolean);
  assert.ok(lines.includes('artifacts/a.gif'));
  assert.ok(lines.includes('artifacts/b.gif'));
  assert.ok(lines.includes('other.png'));
  assert.equal(lines.length, 3);

  const output = readFileSync(githubOutput, 'utf8');
  assert.ok(output.includes('matched=true'));
});

test('detect: newline-separated globs expand', () => {
  const ws = makeWorkspace('ws2', {
    'artifacts/a.gif': 'x',
    'artifacts/b.gif': 'x',
  });

  const list = expandFiles('artifacts/a.gif\nartifacts/b.gif', ws);
  assert.deepEqual(list, ['artifacts/a.gif', 'artifacts/b.gif']);
});

test('detect: ** recursive match', () => {
  const ws = makeWorkspace('ws3', {
    'artifacts/top.gif': 'x',
    'artifacts/deep/nested/low.gif': 'x',
  });

  const list = expandFiles('artifacts/**/*.gif', ws);
  assert.ok(list.includes('artifacts/top.gif'));
  assert.ok(list.includes('artifacts/deep/nested/low.gif'));
});

test('detect: nullglob - zero matches is not an error', () => {
  const ws = makeWorkspace('ws4', {});

  const list = expandFiles('artifacts/*.nope', ws);
  assert.deepEqual(list, []);

  const { rt, githubOutput } = makeRunnerTemp('rt4');

  assert.doesNotThrow(() => {
    detect({
      FILES: 'artifacts/*.nope',
      RUNNER_TEMP: rt,
      GITHUB_OUTPUT: githubOutput,
      GITHUB_WORKSPACE: ws,
    });
  });

  const filesTxt = readFileSync(path.join(rt, 'files.txt'), 'utf8');
  assert.equal(filesTxt, '');

  const output = readFileSync(githubOutput, 'utf8');
  assert.ok(output.includes('matched=false'));
});

test('detect: paths are ./-stripped and sorted/unique', () => {
  const ws = makeWorkspace('ws5', {
    'artifacts/z.gif': 'x',
    'artifacts/a.gif': 'x',
  });

  const list = expandFiles(
    './artifacts/z.gif ./artifacts/a.gif artifacts/z.gif',
    ws,
  );
  assert.deepEqual(list, ['artifacts/a.gif', 'artifacts/z.gif']);
});

// =============================================================================
// isImagePath
// =============================================================================

test('isImagePath: recognises common image extensions case-insensitively', () => {
  assert.equal(isImagePath('shot.png'), true);
  assert.equal(isImagePath('shot.PNG'), true);
  assert.equal(isImagePath('shot.jpg'), true);
  assert.equal(isImagePath('shot.jpeg'), true);
  assert.equal(isImagePath('shot.gif'), true);
  assert.equal(isImagePath('shot.webp'), true);
  assert.equal(isImagePath('shot.svg'), true);
  assert.equal(isImagePath('shot.avif'), true);
  assert.equal(isImagePath('shot.bmp'), true);
  assert.equal(isImagePath('shot.ico'), true);
});

test('isImagePath: non-image files are false', () => {
  assert.equal(isImagePath('report.html'), false);
  assert.equal(isImagePath('trace.zip'), false);
  assert.equal(isImagePath('noext'), false);
});

// =============================================================================
// build / buildBody
// =============================================================================

test('build: image lines built from base with ?raw=true suffix', () => {
  const body = buildBody({
    files: ['artifacts/a.gif'],
    base: 'https://github.example.test/owner/repo/blob/deadbeef/pr-1',
    message: '',
    marker: '<!-- m -->',
  });
  assert.ok(
    body.includes(
      '![artifacts/a.gif](https://github.example.test/owner/repo/blob/deadbeef/pr-1/artifacts/a.gif?raw=true)',
    ),
  );
});

test('build: MESSAGE present at top', () => {
  const body = buildBody({
    files: ['artifacts/a.gif'],
    base: 'https://x',
    message: 'Here are the screenshots',
    marker: '<!-- m -->',
  });
  const lines = body.split('\n');
  assert.equal(lines[0], 'Here are the screenshots');
  assert.equal(lines[1], '');
});

test('build: MESSAGE empty => no message line', () => {
  const body = buildBody({
    files: ['artifacts/a.gif'],
    base: 'https://x',
    message: '',
    marker: '<!-- m -->',
  });
  const firstLine = body.split('\n')[0];
  assert.ok(firstLine.startsWith('![artifacts/a.gif]'));
});

test('build: MARKER is the last line and matches input', () => {
  const marker = '<!-- artifact-branch-comment-files -->';
  const body = buildBody({
    files: ['artifacts/a.gif'],
    base: 'https://x',
    message: '',
    marker,
  });
  // body ends with `${marker}\n`, so splitting on '\n' yields a trailing ''.
  const lines = body.split('\n');
  assert.equal(lines[lines.length - 2], marker);
});

test('build: subdirectory relpath preserved in alt text', () => {
  const body = buildBody({
    files: ['a/b/c.gif'],
    base: 'https://host/base',
    message: '',
    marker: '<!-- m -->',
  });
  assert.ok(body.includes('![a/b/c.gif](https://host/base/a/b/c.gif?raw=true)'));
});

test('build: multiple files each get a line', () => {
  const body = buildBody({
    files: ['artifacts/a.gif', 'artifacts/b.gif'],
    base: 'https://h',
    message: '',
    marker: '<!-- m -->',
  });
  assert.ok(body.includes('![artifacts/a.gif](https://h/artifacts/a.gif?raw=true)'));
  assert.ok(body.includes('![artifacts/b.gif](https://h/artifacts/b.gif?raw=true)'));
});

test('build: filenames with spaces are percent-encoded in the URL', () => {
  const body = buildBody({
    files: ['artifacts/a b.gif'],
    base: 'https://h',
    message: '',
    marker: '<!-- m -->',
  });
  // Alt text keeps the raw name; only the URL segment is encoded, and the
  // ?raw=true suffix is preserved.
  assert.ok(
    body.includes('![artifacts/a b.gif](https://h/artifacts/a%20b.gif?raw=true)'),
  );
});

test('build: non-image files only => bulleted links, no image lines', () => {
  const body = buildBody({
    files: ['artifacts/report.html', 'artifacts/trace.zip'],
    base: 'https://h',
    message: '',
    marker: '<!-- m -->',
  });
  assert.ok(body.includes('- [artifacts/report.html](https://h/artifacts/report.html?raw=true)'));
  assert.ok(body.includes('- [artifacts/trace.zip](https://h/artifacts/trace.zip?raw=true)'));
  assert.ok(!body.includes('!['));
});

test('build: mixed files => non-image bullet list appears before image lines', () => {
  const body = buildBody({
    files: ['artifacts/report.html', 'artifacts/a.png', 'artifacts/trace.zip'],
    base: 'https://h',
    message: 'Files:',
    marker: '<!-- m -->',
  });

  const bulletIndex = body.indexOf('- [artifacts/report.html]');
  const zipBulletIndex = body.indexOf('- [artifacts/trace.zip]');
  const imageIndex = body.indexOf('![artifacts/a.png]');
  const markerIndex = body.indexOf('<!-- m -->');
  const messageIndex = body.indexOf('Files:');

  assert.ok(messageIndex >= 0);
  assert.ok(bulletIndex > messageIndex);
  assert.ok(zipBulletIndex > messageIndex);
  assert.ok(imageIndex > bulletIndex);
  assert.ok(imageIndex > zipBulletIndex);
  assert.ok(markerIndex > imageIndex);
});

test('build: body written to both comment-body.md and step summary', () => {
  const rt = path.join(TMP, 'brt1');
  mkdirSync(rt, { recursive: true });
  writeFileSync(path.join(rt, 'files.txt'), 'artifacts/a.gif\n');
  const summary = path.join(rt, 'step_summary');
  writeFileSync(summary, '');

  build({
    RUNNER_TEMP: rt,
    SERVER_URL: 'https://h',
    GITHUB_REPOSITORY: 'o/r',
    COMMIT_SHA: 'deadbeef',
    DEST_DIR: 'pr-1',
    MESSAGE: 'Hello',
    MARKER: '<!-- m -->',
    GITHUB_STEP_SUMMARY: summary,
  });

  const bodyContent = readFileSync(path.join(rt, 'comment-body.md'), 'utf8');
  assert.ok(bodyContent.length > 0);
  assert.ok(bodyContent.includes('![artifacts/a.gif](https://h/o/r/blob/deadbeef/pr-1/artifacts/a.gif?raw=true)'));

  const summaryContent = readFileSync(summary, 'utf8');
  assert.ok(summaryContent.includes('![artifacts/a.gif](https://h/o/r/blob/deadbeef/pr-1/artifacts/a.gif?raw=true)'));
  assert.ok(summaryContent.split('\n').includes('Hello'));
  assert.equal(summaryContent, bodyContent);
});

// =============================================================================
// CLI
// =============================================================================

test('CLI: unknown mode exits 1 with stderr message', () => {
  const result = spawnSync('node', [scriptPath, 'bogus']);
  assert.equal(result.status, 1);
  assert.ok(
    result.stderr.toString().includes(
      "comment.mjs: unknown mode 'bogus' (expected detect|build)",
    ),
  );
});
