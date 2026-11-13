#!/usr/bin/env node
// Guards the write path for automation-condition comparisons.
//
// The unit tests cover the operator vocabulary and the CLI/app/Node contracts, but the
// last step — handing a comparison to HMEventTrigger — cannot be unit tested: HMCharacteristic
// cannot be constructed in a test, and the app target only builds under the Catalyst job.
// Reverting either call site to a hardcoded `relatedBy: .equalTo` would therefore leave
// every test green while the feature silently did nothing. This check reads the source
// instead, so that regression fails CI.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

const root = fileURLToPath(new URL('../', import.meta.url));
const managerPath = resolve(root, 'Sources/homeclaw/HomeKit/HomeKitManager.swift');
const comparisonPath = resolve(root, 'Sources/homeclaw/HomeKit/ConditionComparison.swift');
const schemaPath = resolve(root, 'lib/schemas.js');

export async function checkConditionOperators() {
  const manager = await readFile(managerPath, 'utf8');

  // 1. No predicate may be built with a constant relation again. This is the exact
  //    pre-feature shape of both call sites.
  assert.ok(
    !/relatedBy:\s*\.equalTo\b/.test(manager),
    'HomeKitManager builds a predicate with a hardcoded `.equalTo`; conditions must use ConditionComparison.nsOperator'
  );

  // 2. Both predicate-building sites must derive the relation from a resolved comparison.
  const relationSources = [...manager.matchAll(/relatedBy:\s*([A-Za-z0-9_.]+)/g)].map(match => match[1]);
  const expected = ['cond.comparison.nsOperator', 'effectiveComparison.nsOperator'];
  for (const source of expected) {
    assert.ok(
      relationSources.includes(source),
      `expected a predicate built with relatedBy: ${source} (found: ${relationSources.join(', ') || 'none'})`
    );
  }
  assert.equal(
    relationSources.length,
    expected.length,
    `unexpected extra predicate relation source(s): ${relationSources.join(', ')}`
  );

  // 3. The enum must still be the six canonical symbols the read side reports, so a
  //    read -> edit -> write round trip keeps working.
  const comparisonSource = await readFile(comparisonPath, 'utf8');
  const cases = [...comparisonSource.matchAll(/case \w+ = "([^"]+)"/g)].map(match => match[1]);
  assert.deepEqual(cases, ['==', '!=', '<', '<=', '>', '>='], `unexpected operator cases: ${cases.join(', ')}`);

  // 4. The published schema must accept every canonical spelling plus the mnemonics the
  //    description promises — a schema that rejects what the socket accepts fails the
  //    caller before our own validation can speak.
  const { tools } = await import(pathToFileURL(schemaPath).href);
  const automations = tools.find(tool => tool.name === 'homekit_automations');
  assert.ok(automations, 'homekit_automations tool missing from lib/schemas.js');
  const allowed = automations.inputSchema.properties.condition.properties.operator.enum;
  for (const spelling of [...cases, 'eq', 'ne', 'lt', 'lte', 'gt', 'gte']) {
    assert.ok(allowed.includes(spelling), `schema operator enum should accept '${spelling}'`);
  }
  const rowsEnum = automations.inputSchema.properties.conditions.items.properties.operator.enum;
  assert.deepEqual(rowsEnum, allowed, 'condition and conditions[] operator enums must agree');

  // 5. The CLI keeps its own copy of the operator vocabulary and the prefix splitter, because
  //    it cannot import the app target. That copy has drifted twice already — once letting the
  //    CLI split a prefix the app had stopped splitting. Compare the prefix tables themselves,
  //    in order, so a symbol added to one side and not the other fails here. Comparing a
  //    filtered set would hide exactly the extra-operator case this is meant to catch.
  const rowJSONPath = resolve(root, 'Sources/homeclaw-cli/Commands/RowJSON.swift');
  const rowJSON = await readFile(rowJSONPath, 'utf8');

  const prefixTable = (source, pattern) => {
    const block = source.match(pattern);
    assert.ok(block, 'could not locate the operator prefix table to compare');
    // Each entry is a tuple whose first element is the operator symbol, so take only that.
    return [...block[1].matchAll(/\(\s*"([^"]+)"/g)].map(match => match[1]);
  };
  const cliPrefixes = prefixTable(rowJSON, /let prefixes: \[\(String, String\)\] = \[([\s\S]*?)\]/);
  const appPrefixes = prefixTable(comparisonSource, /let prefixes: \[\(String, ConditionComparison\)\] = \[([\s\S]*?)\]/);
  assert.deepEqual(
    cliPrefixes,
    appPrefixes,
    `CLI prefix table (${cliPrefixes.join(', ')}) differs from the app's (${appPrefixes.join(', ')}); the two copies must list the same operators in the same order`
  );

  // 6. The CLI splitter must gate prefix peeling on the decimal rule. Scope this to the
  //    splitter's own body and match the call rather than an exact argument name: a renamed
  //    local variable is a harmless edit and must not fail CI, but dropping the call is the
  //    regression that let `inf`/`nan`/hex text be peeled.
  const splitterStart = rowJSON.indexOf('static func splitComparisonPrefix');
  assert.ok(splitterStart !== -1, 'could not locate RowJSON.splitComparisonPrefix');
  const splitterRest = rowJSON.slice(splitterStart);
  const splitterEnd = splitterRest.indexOf('\n    }');
  const splitterBody = splitterEnd === -1 ? splitterRest : splitterRest.slice(0, splitterEnd);
  assert.ok(
    /isDecimalThreshold\s*\(/.test(splitterBody),
    'RowJSON.splitComparisonPrefix must gate prefix peeling on isDecimalThreshold so `inf`/`nan`/hex text stays literal'
  );

  return { relations: relationSources, operators: cases.length };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { relations, operators } = await checkConditionOperators();
    console.log(
      `Condition operator wiring OK: ${operators} operators, predicate relations from ${relations.join(' + ')}`
    );
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
