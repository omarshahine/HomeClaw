import assert from 'node:assert/strict';
import fs from 'node:fs';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { runInNewContext } from 'node:vm';
import test from 'node:test';

const require = createRequire(import.meta.url);
const npmManifest = require.resolve('npm/package.json');
const npmRequire = createRequire(npmManifest);
const npmRoot = dirname(npmManifest);
const semver = npmRequire('semver');

test('installed security bundle contains the pinned upstream fixes', () => {
  assert.equal(npmRequire('./package.json').version, '12.2.1+security.20261031');
  for (const [name, version] of Object.entries({
    'ip-address': '10.7.4', undici: '6.29.1', glob: '14.0.3',
    minimatch: '11.0.3', 'path-scurry': '3.0.0',
    '@isaacs/nonrecursive-glob-match': '1.0.3',
  })) {
    assert.equal(npmRequire(`${name}/package.json`).version, version, name);
  }
  assert.equal(require('minimatch/package.json').version, '11.0.3');
});

test('bundled npm consumers resolve compatible patched dependency ranges', () => {
  let checked = 0;
  const visit = directory => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const child = join(directory, entry.name);
      const manifestPath = join(child, 'package.json');
      if (fs.existsSync(manifestPath)) {
        const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
        const fromPackage = createRequire(manifestPath);
        for (const name of ['glob', 'minimatch', 'path-scurry', '@isaacs/nonrecursive-glob-match']) {
          const range = manifest.dependencies?.[name];
          if (!range) continue;
          const version = fromPackage(`${name}/package.json`).version;
          assert.ok(semver.satisfies(version, range), `${manifest.name}: ${name}@${version} does not satisfy ${range}`);
          checked++;
        }
      }
      visit(child);
    }
  };
  visit(join(npmRoot, 'node_modules'));
  assert.ok(checked >= 10, `Only checked ${checked} bundled dependency edges`);
});

test('glob cancellation stops background filesystem traversal', async t => {
  const root = fs.mkdtempSync(join(tmpdir(), 'npm-glob-abort-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (let i = 0; i < 8; i++) fs.mkdirSync(join(root, `a${i}`, 'b', 'c'), { recursive: true });
  const controller = new AbortController();
  const reason = new Error('fixture abort');
  let reads = 0;
  const instrumented = {
    ...fs,
    readdir(...args) {
      reads++;
      const callback = args.pop();
      fs.readdir(...args, (...result) => {
        controller.abort(reason);
        callback(...result);
      });
    },
  };
  await assert.rejects(npmRequire('glob').glob('**/*', {
    cwd: root, signal: controller.signal, fs: instrumented,
  }), error => error === reason);
  const settled = reads;
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.ok(settled > 0);
  assert.equal(reads, settled, 'Filesystem traversal continued after cancellation');
});

test('minimatch handles amplification patterns within a bounded child process', () => {
  const result = spawnSync(process.execPath, ['--input-type=commonjs', '-e',
    "const {minimatch}=require(process.argv[1]); const result=minimatch('path/file.js','**/../'.repeat(20)+'*.js',{optimizationLevel:2}); if(typeof result!=='boolean') process.exit(1)",
    npmRequire.resolve('minimatch'),
  ], { encoding: 'utf8', timeout: 2000 });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stderr);
});

test('OpenClaw resolves its declared limiter while legacy consumers retain theirs', async () => {
  const fromOpenClaw = createRequire(new URL('../node_modules/openclaw/package.json', import.meta.url));
  const version = from => JSON.parse(fs.readFileSync(join(dirname(from.resolve('p-limit')), 'package.json'), 'utf8')).version;
  assert.equal(version(fromOpenClaw), '7.3.3');
  const fromLocate = createRequire(fromOpenClaw.resolve('p-locate'));
  assert.equal(version(fromLocate), '2.3.0');
  const { default: pLimit, limitFunction } = await import(pathToFileURL(fromOpenClaw.resolve('p-limit')));
  assert.equal(typeof limitFunction, 'function');
  const limit = pLimit(2);
  let active = 0;
  let peak = 0;
  await Promise.all(Array.from({ length: 6 }, () => limit(async () => {
    peak = Math.max(peak, ++active);
    await new Promise(resolve => setTimeout(resolve, 2));
    active--;
  })));
  assert.equal(peak, 2);
});

test('installed OpenClaw expands wildcard environment-file paths with minimatch 11', async t => {
  const root = fs.mkdtempSync(join(tmpdir(), 'openclaw-pattern-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const name of ['first.env', 'second.env', 'other.txt']) fs.writeFileSync(join(root, name), 'FIXTURE=true');
  const source = fs.readFileSync(new URL('../node_modules/openclaw/dist/systemd-service-files-ByFWlfWV.mjs', import.meta.url), 'utf8');
  const region = source.split('//#region src/daemon/systemd-environment-file-pattern.ts\n')[1]?.split('//#endregion')[0];
  assert.ok(region, 'Locked consumer region is missing');
  // Execute the installed consumer's actual function in a context containing only
  // its filesystem/matcher dependencies; do not initialize an OpenClaw host.
  const expand = runInNewContext(`(${region.trim()})`, {
    fs$1: fs.promises, Minimatch: require('minimatch').Minimatch,
    hasErrnoCode: (error, code) => error?.code === code,
  });
  const matches = await expand(join(root, '*.env'));
  assert.deepEqual(Array.from(matches).sort(), ['first.env', 'second.env'].map(name => join(root, name)));
  assert.deepEqual(Array.from(await expand(join(root, 'missing*.env'))), []);
});

test('OpenClaw compatibility patch is idempotent and rejects upstream drift', t => {
  const root = fs.mkdtempSync(join(tmpdir(), 'openclaw-patch-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const host = join(root, 'node_modules/openclaw');
  fs.mkdirSync(join(host, 'dist'), { recursive: true });
  fs.mkdirSync(join(root, 'scripts'));
  fs.writeFileSync(join(host, 'package.json'), JSON.stringify({ name: 'openclaw', version: '2026.10.5' }));
  const script = join(root, 'scripts/patch-openclaw-minimatch.mjs');
  fs.copyFileSync(new URL('./patch-openclaw-minimatch.mjs', import.meta.url), script);
  const consumer = join(host, 'dist/systemd-service-files-ByFWlfWV.mjs');
  const installed = fs.readFileSync(new URL('../node_modules/openclaw/dist/systemd-service-files-ByFWlfWV.mjs', import.meta.url), 'utf8');
  fs.writeFileSync(consumer, installed.replace('part !== null && typeof part === "object" && typeof part.test === "function" && part.test(entry)', 'part instanceof RegExp && part.test(entry)'));
  const run = () => spawnSync(process.execPath, [script], { encoding: 'utf8', timeout: 2000 });
  assert.equal(run().status, 0);
  assert.equal(fs.readFileSync(consumer, 'utf8'), installed);
  assert.equal(run().status, 0);
  fs.appendFileSync(consumer, '\n// upstream drift\n');
  const changed = fs.readFileSync(consumer, 'utf8');
  const rejected = run();
  assert.equal(rejected.status, 1);
  assert.match(rejected.stderr, /consumer changed/);
  assert.equal(fs.readFileSync(consumer, 'utf8'), changed);
  const outside = join(root, 'outside-host');
  fs.renameSync(host, outside);
  fs.symlinkSync(outside, host, 'dir');
  assert.match(run().stderr, /outside this repository/);
});

test('root install hook supports lockfile-only and MCP-only workspace operations', t => {
  const root = fs.mkdtempSync(join(tmpdir(), 'openclaw-absent-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(join(root, 'scripts'));
  fs.mkdirSync(join(root, 'mcp-server'));
  fs.copyFileSync(new URL('./patch-openclaw-minimatch.mjs', import.meta.url), join(root, 'scripts/patch-openclaw-minimatch.mjs'));
  fs.writeFileSync(join(root, 'package.json'), JSON.stringify({
    name: 'fixture-root', version: '1.0.0', private: true,
    workspaces: ['mcp-server'], scripts: { postinstall: 'node scripts/patch-openclaw-minimatch.mjs' },
  }));
  fs.writeFileSync(join(root, 'mcp-server/package.json'), JSON.stringify({ name: '@homeclaw/mcp-server', version: '1.0.0' }));
  for (const args of [['install', '--package-lock-only'], ['ci', '--workspace=@homeclaw/mcp-server']]) {
    const result = spawnSync(process.execPath, [join(npmRoot, 'bin/npm-cli.js'), ...args, '--offline', '--cache', join(root, 'cache')], {
      cwd: root, encoding: 'utf8', timeout: 15000,
      env: { PATH: process.env.PATH, HOME: root,
        NPM_CONFIG_USERCONFIG: join(root, 'user.npmrc'),
        NPM_CONFIG_GLOBALCONFIG: join(root, 'global.npmrc') },
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /OpenClaw is not installed/);
    assert.equal(fs.existsSync(join(root, 'node_modules/openclaw')), false);
  }
});

test('patched npm installs, discovers and packs workspaces offline', t => {
  const root = fs.mkdtempSync(join(tmpdir(), 'npm-workspace-compat-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const write = (path, value) => fs.writeFileSync(join(root, path), JSON.stringify(value));
  for (const name of ['a', 'b']) fs.mkdirSync(join(root, 'packages', name), { recursive: true });
  write('package.json', { name: 'fixture-root', private: true, workspaces: ['packages/*'] });
  write('packages/a/package.json', { name: 'fixture-a', version: '1.0.0' });
  write('packages/b/package.json', { name: 'fixture-b', version: '1.0.0', dependencies: { 'fixture-a': '^1.0.0' } });
  const run = (...args) => {
    const result = spawnSync(process.execPath, [join(npmRoot, 'bin/npm-cli.js'), ...args,
      '--offline', '--ignore-scripts', '--cache', join(root, 'cache'),
    ], {
      cwd: root, encoding: 'utf8', timeout: 15000,
      env: { PATH: process.env.PATH, HOME: root,
        NPM_CONFIG_USERCONFIG: join(root, 'user.npmrc'),
        NPM_CONFIG_GLOBALCONFIG: join(root, 'global.npmrc') },
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  run('install', '--json');
  assert.deepEqual(Object.keys(run('pkg', 'get', 'name', '--workspaces', '--json')).sort(), ['fixture-a', 'fixture-b']);
  const packages = Object.values(run('pack', '--dry-run', '--workspaces', '--json'));
  assert.deepEqual(packages.map(item => item.name).sort(), ['fixture-a', 'fixture-b']);
});
