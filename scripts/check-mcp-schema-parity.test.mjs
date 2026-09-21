import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { checkParity } from './check-mcp-schema-parity.mjs';

const schemaURL = new URL('../lib/schemas.js', import.meta.url);

test('complete canonical descriptors match the actual Node export', async () => {
  assert.ok(await checkParity() > 0);
});

// Mutate real schema source in temporary ESM modules: never change the checkout
// or start a Node server/CLI/HomeKit connection. Names alone remain unchanged.
for (const [label, mutation] of [
  ['description', "tools[0].description += ' changed';"],
  ['nested property type', "tools[1].inputSchema.properties.service_index.type = 'string';"],
  ['action enum', "tools[1].inputSchema.properties.action.enum.push('future_action');"],
  ['required fields', "tools[1].inputSchema.required = ['accessory_id'];"],
  ['new descriptor field', "tools[0].annotations = { readOnlyHint: true };"],
  ['removed tool', 'tools.pop();'],
]) {
  test(`rejects Node schema drift: ${label}`, async () => {
    const directory = await mkdtemp(join(tmpdir(), 'homeclaw-schema-'));
    try {
      const path = join(directory, 'schemas.mjs');
      await writeFile(path, `${await readFile(schemaURL, 'utf8')}\n${mutation}\n`);
      await assert.rejects(checkParity(path), /Swift descriptors drifted/);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });
}

test('parity tests never invoke the live HomeKit dispatcher', async () => {
  const source = await readFile(new URL('../Tests/HomeClawTests/MCPTransportParityTests.swift', import.meta.url), 'utf8');
  assert.doesNotMatch(source, /ToolHandlers\.call\s*\(/,
    'Parity tests must use a recording registry, not live HomeKit operations');
  assert.doesNotMatch(source, /MCPServer\(\)/,
    'Parity transports must receive an explicit non-actuating registry');
});
