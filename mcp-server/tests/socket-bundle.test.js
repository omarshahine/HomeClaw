import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { join } from 'node:path';
import test from 'node:test';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

test('bundled stdio MCP server discovers an app launched after initialization', async t => {
  const home = await mkdtemp('/tmp/hcmcp-');
  const socketDirectory = join(home, 'Library/Group Containers/group.com.shahine.homeclaw');
  const socketPath = join(socketDirectory, 'homeclaw.sock');
  const bundlePath = join(home, 'server.mjs');
  const bundle = await readFile(new URL('../dist/server.js', import.meta.url), 'utf8');
  // Isolate the legacy fallback too: even a regression must never connect to
  // an installed app or touch a real home during this protocol test.
  const isolatedBundle = bundle.replaceAll('/tmp/homeclaw.sock', join(home, 'legacy.sock'));
  assert.notEqual(isolatedBundle, bundle);
  const client = new Client({ name: 'homeclaw-regression', version: '1.0.0' });
  const requests = [];
  const sockets = new Set();
  const server = createServer(socket => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
    let data = '';
    socket.on('data', chunk => {
      data += chunk;
      if (!data.includes('\n')) return;
      requests.push(JSON.parse(data));
      socket.end(JSON.stringify({ success: true, data: { fixture: true } }));
    });
  });
  t.after(async () => {
    await client.close();
    for (const socket of sockets) socket.destroy();
    if (server.listening) await new Promise(resolve => server.close(resolve));
    await rm(home, { recursive: true, force: true });
  });
  await mkdir(socketDirectory, { recursive: true });
  await writeFile(bundlePath, isolatedBundle);
  await client.connect(new StdioClientTransport({
    command: process.execPath,
    args: [bundlePath],
    env: { HOME: home },
  }));
  const { version } = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(client.getServerVersion().version, version);
  assert.ok((await client.listTools()).tools.some(tool => tool.name === 'homekit_status'));

  // The bridge is already initialized and its handlers imported before the
  // simulated App Store app starts listening in its App Group container.
  server.listen(socketPath);
  await once(server, 'listening');
  const result = await client.callTool({ name: 'homekit_status', arguments: {} });
  assert.equal(result.isError, undefined);
  assert.deepEqual(JSON.parse(result.content[0].text), { fixture: true });
  assert.deepEqual(requests, [{ command: 'status', args: {} }]);
});
