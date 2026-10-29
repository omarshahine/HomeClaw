import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, readdirSync, rmdirSync, unlinkSync } from 'node:fs';
import { createServer } from 'node:net';
import { join } from 'node:path';
import test from 'node:test';
import { createSocketClient } from '../../lib/socket-client.js';

function fixture(t, timeoutMs = 1000) {
  // Short paths also fit Darwin's 104-byte Unix socket address limit.
  const directory = mkdtempSync('/tmp/hc-');
  const paths = [join(directory, 'app.sock'), join(directory, 'legacy.sock')];
  const servers = [];
  t.after(async () => {
    for (const server of servers) {
      if (server.listening) await new Promise(resolve => server.close(resolve));
    }
    for (const file of readdirSync(directory)) unlinkSync(join(directory, file));
    rmdirSync(directory);
  });
  async function listen(path, respond = () => ({ success: true, data: { path } })) {
    const requests = [];
    const server = createServer(socket => {
      let data = '';
      socket.on('error', () => {});
      socket.on('data', chunk => {
        data += chunk;
        if (!data.includes('\n')) return;
        const request = JSON.parse(data);
        requests.push(request);
        const response = respond(request, socket);
        if (response !== undefined) {
          socket.end(typeof response === 'string' ? response : JSON.stringify(response));
        }
      });
    });
    servers.push(server);
    server.listen(path);
    await once(server, 'listening');
    return { server, requests };
  }
  return { paths, listen, send: createSocketClient(paths, timeoutMs) };
}

function leaveStaleSocket(path) {
  // Exiting without server.close() leaves a real socket with no listener.
  const child = spawnSync(process.execPath, ['--input-type=module', '-e',
    "import { createServer } from 'node:net'; createServer().listen(process.argv[1], () => process.exit(0));",
    path,
  ]);
  assert.equal(child.status, 0, child.stderr.toString());
}

test('a client started before HomeClaw discovers the App Group socket later', async t => {
  const { paths, listen, send } = fixture(t);
  await assert.rejects(send('status'), error => {
    assert.match(error.message, /Launch HomeClaw.app/);
    for (const path of paths) assert.ok(error.message.includes(`${path}: ENOENT`));
    return true;
  });
  const { requests } = await listen(paths[0]);
  assert.deepEqual(await send('status'), { path: paths[0] });
  assert.deepEqual(requests, [{ command: 'status', args: {} }]);
});

test('prefers App Group when both sockets are available', async t => {
  const { paths, listen, send } = fixture(t);
  await listen(paths[0]);
  const legacy = await listen(paths[1]);
  assert.deepEqual(await send('status'), { path: paths[0] });
  assert.equal(legacy.requests.length, 0);
});

test('keeps legacy compatibility and follows a later App Group launch', async t => {
  const { paths, listen, send } = fixture(t);
  const legacy = await listen(paths[1]);
  assert.deepEqual(await send('status', { home_id: 'fixture' }), { path: paths[1] });
  assert.deepEqual(legacy.requests, [{ command: 'status', args: { home_id: 'fixture' } }]);
  await new Promise(resolve => legacy.server.close(resolve));
  await listen(paths[0]);
  assert.deepEqual(await send('status'), { path: paths[0] });
});

test('falls back from an unconnectable old App Group path', async t => {
  const { paths, listen, send } = fixture(t);
  leaveStaleSocket(paths[0]);
  await listen(paths[1]);
  assert.deepEqual(await send('status'), { path: paths[1] });
});

test('reports every attempted path when neither socket accepts connections', async t => {
  const { paths, send } = fixture(t);
  leaveStaleSocket(paths[0]);
  await assert.rejects(send('status'), error => {
    assert.ok(error.message.includes(`${paths[0]}: ECONNREFUSED`));
    assert.ok(error.message.includes(`${paths[1]}: ENOENT`));
    return true;
  });
});

test('preserves UTF-8 response strings split across socket data events', async t => {
  const { paths, listen, send } = fixture(t);
  const expected = { name: 'Café 💡' };
  const response = Buffer.from(JSON.stringify({ success: true, data: expected }));
  const accentSplit = response.indexOf(Buffer.from('é')) + 1;
  const emojiSplit = response.indexOf(Buffer.from('💡')) + 2;
  await listen(paths[0], (_request, socket) => {
    socket.write(response.subarray(0, accentSplit));
    setTimeout(() => {
      socket.write(response.subarray(accentSplit, emojiSplit));
      setTimeout(() => socket.end(response.subarray(emojiSplit)), 20);
    }, 20);
  });
  assert.deepEqual(await send('status'), expected);
});

for (const [name, respond, error] of [
  ['an application error', () => ({ success: false, error: 'fixture rejected' }), /fixture rejected/],
  ['invalid JSON', () => 'bad JSON', /Failed to parse response/],
  ['a disconnect without a response', () => '', /Failed to parse response/],
  ['a timeout after dispatch', () => undefined, /request timed out/],
]) {
  test(`never replays a command after ${name}`, async t => {
    const { paths, listen, send } = fixture(t, 100);
    const preferred = await listen(paths[0], respond);
    const legacy = await listen(paths[1]);
    await assert.rejects(send('control', { value: true }), error);
    assert.equal(preferred.requests.length, 1);
    assert.equal(legacy.requests.length, 0);
  });
}
