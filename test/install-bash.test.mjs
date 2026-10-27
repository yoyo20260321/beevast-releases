import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const installer = fileURLToPath(new URL('../install.sh', import.meta.url));
const bash = '/bin/bash';
const version = spawnSync(bash, ['--version'], { encoding: 'utf8' });
assert.equal(version.status, 0);
assert.match(version.stdout, /version 3\.2\./);

// PATH has no system fallback: every external command except Node is a stub.
// The first installation mkdir exits before extraction, product/RC/launchd writes.
const stub = `#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const name = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const root = process.env.INSTALL_TEST_ROOT;
fs.appendFileSync(path.join(root, 'calls.jsonl'), JSON.stringify({name, args}) + '\\n');
function fail() { console.error('FORBIDDEN COMMAND', name, JSON.stringify(args)); process.exit(97); }
switch (name) {
  case 'ssh':
    if (JSON.stringify(args) !== JSON.stringify(['-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', 'git@github.com'])) fail();
    console.log('Hi synthetic! You have successfully authenticated.');
    break;
  case 'grep':
    if (JSON.stringify(args) !== JSON.stringify(['-q', 'successfully authenticated'])) fail();
    process.exit(fs.readFileSync(0, 'utf8').includes('successfully authenticated') ? 0 : 1);
  case 'mktemp':
    if (JSON.stringify(args) !== JSON.stringify(['-d'])) fail();
    console.log(path.join(root, 'download'));
    break;
  case 'curl': {
    const output = args.indexOf('-o');
    if (output < 0) {
      process.stdout.write(fs.readFileSync(path.join(root, 'release.json')));
    } else {
      if (args[output + 1] !== path.join(root, 'download', 'beevast.tar.gz')) fail();
      fs.writeFileSync(args[output + 1], 'synthetic download placeholder');
    }
    break;
  }
  case 'du':
    if (JSON.stringify(args) !== JSON.stringify(['-h', path.join(root, 'download', 'beevast.tar.gz')])) fail();
    console.log('4K\\tplaceholder');
    break;
  case 'cut':
    if (JSON.stringify(args) !== JSON.stringify(['-f1'])) fail();
    console.log(fs.readFileSync(0, 'utf8').split('\\t')[0]);
    break;
  case 'mkdir':
    if (JSON.stringify(args) !== JSON.stringify(['-p', path.join(root, 'prefix', 'bin')])) fail();
    console.error('INSTALL_TEST_STOP_BEFORE_EXTRACTION');
    process.exit(86);
  case 'rm':
    if (JSON.stringify(args) !== JSON.stringify(['-rf', path.join(root, 'download')])) fail();
    break; // Parent test owns cleanup; never execute real rm.
  default: fail();
}
`;

for (const privateRepo of [false, true]) {
  test(`Bash 3.2 full installer: ${privateRepo ? 'private complete auth' : 'public zero auth'}`, (t) => {
    const root = mkdtempSync(join(tmpdir(), 'install-bash-'));
    try {
      const bin = join(root, 'stubs');
      mkdirSync(bin);
      mkdirSync(join(root, 'download'));
      writeFileSync(join(root, 'calls.jsonl'), '');
      const stubPath = join(root, 'stub.cjs');
      writeFileSync(stubPath, stub, { mode: 0o755 });
      for (const name of ['ssh', 'curl', 'grep', 'mktemp', 'du', 'cut', 'mkdir', 'rm',
        'tar', 'mv', 'chmod', 'git', 'launchctl', 'cp', 'head', 'cat', 'dirname', 'uname', 'id', 'tee',
        'sh', 'bash', 'zsh', 'sudo', 'env', 'wget', 'open']) {
        symlinkSync(stubPath, join(bin, name));
      }
      symlinkSync(process.execPath, join(bin, 'node'));
      const repo = privateRepo ? 'synthetic-owner/test-releases' : 'yoyo20260321/beevast-releases';
      const publicUrl = 'https://synthetic.invalid/download/beevast-1.2.3.tar.gz';
      const privateUrl = 'https://api.github.com/repos/synthetic-owner/test-releases/releases/assets/123';
      const token = 'synthetic token with spaces & punctuation';
      writeFileSync(join(root, 'release.json'), JSON.stringify([{
        tag_name: 'beevast-v1.2.3', draft: false, prerelease: false,
        assets: [{ name: 'beevast-1.2.3.tar.gz', url: privateUrl, browser_download_url: publicUrl }],
      }]));
      const env = { ...process.env };
      for (const key of Object.keys(env)) {
        if (key.startsWith('BEEVAST_') || ['GITHUB_TOKEN', 'BASH_ENV', 'ENV', 'NODE_OPTIONS', 'SHELLOPTS', 'BASHOPTS'].includes(key)
          || key.startsWith('BASH_FUNC_')) delete env[key];
      }
      Object.assign(env, { PATH: bin, BEEVAST_PREFIX: join(root, 'prefix'), BEEVAST_REPO: repo, INSTALL_TEST_ROOT: root });
      if (privateRepo) env.GITHUB_TOKEN = token;
      const result = spawnSync(bash, [installer], { env, cwd: root, encoding: 'utf8', timeout: 15000 });
      const calls = readFileSync(join(root, 'calls.jsonl'), 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
      t.diagnostic(JSON.stringify({ bash: version.stdout.split('\n')[0], node: process.version,
        privateRepo, status: result.status, signal: result.signal, error: result.error?.message,
        stdout: result.stdout, stderr: result.stderr, calls }));
      assert.ifError(result.error);
      assert.equal(result.signal, null);
      assert.equal(result.status, 86, result.stderr);
      assert.equal(result.stderr, 'INSTALL_TEST_STOP_BEFORE_EXTRACTION\n');
      const curls = calls.filter(({ name }) => name === 'curl').map(({ args }) => args);
      const auth = privateRepo ? ['-H', 'Authorization: token ' + token] : [];
      assert.deepEqual(curls, [
        ['-fsSL', ...auth, '-H', 'Accept: application/vnd.github+json', 'https://api.github.com/repos/' + repo + '/releases?per_page=30'],
        ['-fsSL', ...auth, ...(privateRepo ? ['-H', 'Accept: application/octet-stream'] : []),
          privateRepo ? privateUrl : publicUrl, '-o', join(root, 'download', 'beevast.tar.gz')],
      ]);
      assert.ok(curls.flat().every((arg) => arg !== ''), 'no empty argv');
      assert.equal(calls.filter(({ name }) => name === 'mkdir').length, 1);
      assert.deepEqual(calls.slice(-2).map(({ name }) => name), ['mkdir', 'rm']);
      assert.ok(calls.every(({ name }) => ['ssh', 'grep', 'mktemp', 'curl', 'du', 'cut', 'mkdir', 'rm'].includes(name)));
      assert.equal(readFileSync(join(root, 'download', 'beevast.tar.gz'), 'utf8'), 'synthetic download placeholder');
      assert.equal(existsSync(join(root, 'prefix')), false, 'no installation directory created');
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });
}
