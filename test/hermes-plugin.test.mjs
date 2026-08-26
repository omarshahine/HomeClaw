import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

async function readJSON(name) {
  return JSON.parse(await readFile(resolve(root, name), "utf8"));
}

test("HomeClaw portable plugin manifest identifies the MCP component", async () => {
  const manifest = await readJSON("plugin.json");
  assert.equal(manifest.$schema, "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json");
  assert.equal(manifest.name, "homeclaw");
  assert.equal(manifest.version, "1.0.5");
  assert.match(manifest.description, /HomeKit/i);
  assert.equal(manifest.mcp, true);
});

test("HomeClaw portable MCP config is a safe in-package stdio server", async () => {
  const config = await readJSON("mcp.json");
  assert.equal(config.$schema, "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json");
  const server = config.mcpServers.homeclaw;
  assert.equal(server.type, "stdio");
  assert.equal(server.command, "node");
  assert.deepEqual(server.args, ["${PLUGIN_ROOT}/mcp-server/dist/server.js"]);
  assert.equal(server.cwd, "${PLUGIN_ROOT}");
  assert.equal(JSON.stringify(config).includes("sudo"), false);
  assert.equal(JSON.stringify(config).includes("password"), false);
});
