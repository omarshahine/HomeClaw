#!/usr/bin/env node
// lib/schemas.js is authoritative. Run this check in CI; regenerate reviewed
// Swift JSON + XCTest fixture with: node scripts/check-mcp-schema-parity.mjs --write
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
export const swiftPath = resolve(root, 'Sources/homeclaw/MCP/ToolHandlers.swift');
export const fixturePath = resolve(root, 'Tests/HomeClawTests/Fixtures/mcp-tools.json');
const schemaPath = resolve(root, 'lib/schemas.js');
const literalPattern = /static let allToolsJSON: Data = Data\(#"""\n([\s\S]*?)\n    """#\.utf8\)/;

export async function checkParity(nodeSchemaPath = schemaPath) {
  const { tools } = await import(pathToFileURL(nodeSchemaPath).href);
  const source = await readFile(swiftPath, 'utf8');
  const literal = source.match(literalPattern);
  assert.ok(literal, 'ToolHandlers must embed readable raw JSON, not an opaque blob');
  assert.deepStrictEqual(JSON.parse(literal[1]), tools, 'Swift descriptors drifted from lib/schemas.js');
  assert.deepStrictEqual(JSON.parse(await readFile(fixturePath, 'utf8')), tools,
    'XCTest fixture drifted from lib/schemas.js');
  assert.equal(new Set(tools.map(tool => tool.name)).size, tools.length, 'Duplicate tool names');
  return tools.length;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.includes('--write')) {
      const { tools } = await import(pathToFileURL(schemaPath).href);
      const json = JSON.stringify(tools, null, 2);
      assert.ok(!json.includes('"""#') && !json.includes('\\#'), 'Unsafe Swift raw-string delimiter');
      const source = await readFile(swiftPath, 'utf8');
      assert.ok(literalPattern.test(source), 'Readable Swift literal not found');
      await writeFile(swiftPath, source.replace(literalPattern, () =>
        `static let allToolsJSON: Data = Data(#"""\n${json.split('\n').map(line => `    ${line}`).join('\n')}\n    """#.utf8)`));
      await writeFile(fixturePath, `${json}\n`);
    }
    console.log(`MCP schema parity OK: ${await checkParity()} complete Node/Swift/fixture descriptors`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
