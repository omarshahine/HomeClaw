// Keep the locked OpenClaw consumer compatible with the patched minimatch API.
// Only this repository's dependency tree is eligible; never patch a global host.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { lstatSync, readFileSync, realpathSync, writeFileSync } from 'node:fs';
import { join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = realpathSync(fileURLToPath(new URL('../', import.meta.url)));
const hostPath = join(root, 'node_modules/openclaw');
try {
  lstatSync(hostPath);
} catch (error) {
  if (error.code !== 'ENOENT') throw error;
  console.log('OpenClaw is not installed; compatibility patch is not needed');
  process.exit(0);
}
const host = realpathSync(hostPath);
assert.ok(host.startsWith(join(root, 'node_modules') + sep), 'Refusing to patch dependencies outside this repository');
const manifest = JSON.parse(readFileSync(join(host, 'package.json'), 'utf8'));
assert.equal(manifest.name, 'openclaw');
assert.equal(manifest.version, '2026.10.5', 'Review the compatibility patch when updating OpenClaw');
const target = join(host, 'dist/systemd-service-files-ByFWlfWV.mjs');
assert.ok(lstatSync(target).isFile() && !lstatSync(target).isSymbolicLink(), 'Unexpected consumer file type');
const before = 'accb93aaa00e4fa3aa177db9764f43e8a4cba9645691fc050d55abdcb32c69a5';
const after = 'e0b63894ca399c2bb7e00507448fba1fd463c30715faa16aa2836c7b0f543b34';
const digest = value => createHash('sha256').update(value).digest('hex');
const source = readFileSync(target, 'utf8');
if (digest(source) === after) {
  console.log('OpenClaw minimatch compatibility patch already verified');
} else {
  assert.equal(digest(source), before, 'OpenClaw consumer changed; refusing an unreviewed patch');
  const patched = source.replace('part instanceof RegExp && part.test(entry)',
    'part !== null && typeof part === "object" && typeof part.test === "function" && part.test(entry)');
  assert.equal(digest(patched), after);
  writeFileSync(target, patched);
  console.log('Applied verified OpenClaw minimatch compatibility patch');
}
