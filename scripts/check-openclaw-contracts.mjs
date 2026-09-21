#!/usr/bin/env node
//
// Verify openclaw/openclaw.plugin.json declares exactly the agent tools that
// openclaw/src/index.ts registers.
//
// OpenClaw refuses to register any tool missing from `contracts.tools`, so a
// tool added to the TOOLS array without a manifest entry silently disappears
// from agents. This also checks that `toolMetadata` covers every tool and that
// its `optional` flag matches the `optional: true` set in TOOLS (the tools
// that change HomeKit state).
//
// Usage: node scripts/check-openclaw-contracts.mjs

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const manifest = JSON.parse(
	readFileSync(join(root, 'openclaw/openclaw.plugin.json'), 'utf8')
);
const source = readFileSync(join(root, 'openclaw/src/index.ts'), 'utf8');

const start = source.indexOf('const TOOLS');
const end = source.indexOf('\n];', start);
if (start === -1 || end === -1) {
	console.error('FAIL: could not find the TOOLS array in openclaw/src/index.ts');
	process.exit(1);
}

// Each tool entry opens with `name: '...'`, optionally followed by
// `optional: true`, at the top indentation level of the TOOLS array.
const entryPattern = /^\t\tname: '([a-z0-9_]+)',\n(\t\toptional: true,)?/gm;
const tools = [...source.slice(start, end).matchAll(entryPattern)].map((m) => ({
	name: m[1],
	optional: Boolean(m[2]),
}));

const errors = [];
const sourceNames = tools.map((t) => t.name);
const declared = manifest.contracts?.tools ?? [];
const metadata = manifest.toolMetadata ?? {};

if (sourceNames.length === 0) errors.push('no tools found in the TOOLS array');

for (const name of sourceNames) {
	if (!declared.includes(name)) errors.push(`${name}: missing from contracts.tools`);
}
for (const name of declared) {
	if (!sourceNames.includes(name)) errors.push(`${name}: in contracts.tools but not in TOOLS`);
}
for (const name of Object.keys(metadata)) {
	if (!declared.includes(name)) errors.push(`${name}: in toolMetadata but not in contracts.tools`);
}
for (const tool of tools) {
	const meta = metadata[tool.name];
	if (!meta) {
		errors.push(`${tool.name}: missing from toolMetadata`);
		continue;
	}
	if ((meta.optional === true) !== tool.optional) {
		errors.push(
			`${tool.name}: toolMetadata.optional is ${meta.optional === true}, TOOLS says ${tool.optional}`
		);
	}
	if (tool.optional && meta.sideEffecting !== true) {
		errors.push(`${tool.name}: optional (state-changing) tool must set sideEffecting: true`);
	}
	if (!tool.optional) {
		// Read-only tools must stay visible in every chat-facing profile and be
		// safe to replay; empty metadata would silently drop them.
		if (meta.replaySafe !== true) errors.push(`${tool.name}: read-only tool must set replaySafe: true`);
		if (meta.sideEffecting === true) errors.push(`${tool.name}: read-only tool must not set sideEffecting`);
		const profiles = Array.isArray(meta.profiles) ? meta.profiles : [];
		for (const profile of ['coding', 'messaging', 'full']) {
			if (!profiles.includes(profile)) errors.push(`${tool.name}: read-only tool missing profile "${profile}"`);
		}
	}
}

if (errors.length > 0) {
	console.error('FAIL: openclaw manifest contracts drifted from src/index.ts');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`OK: ${sourceNames.length} tools declared in contracts.tools and toolMetadata ` +
		`(${tools.filter((t) => t.optional).length} optional/side-effecting)`
);
