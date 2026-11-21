import assert from 'node:assert/strict';
import test from 'node:test';
import { tools } from '../../lib/schemas.js';

const automations = tools.find(tool => tool.name === 'homekit_automations');
const addCondition = automations.inputSchema.properties.condition;

// The schema is the first thing a host validates against, so it must accept every
// spelling the socket accepts. Advertising only symbols while the description promised
// mnemonics meant a validating client rejected `lt` before the handler ever ran.
test('add_condition operator schema accepts symbols and mnemonics', () => {
  const allowed = addCondition.properties.operator.enum;
  for (const spelling of ['==', '!=', '<', '<=', '>', '>=', 'eq', 'ne', 'lt', 'lte', 'gt', 'gte']) {
    assert.ok(allowed.includes(spelling), `schema should accept ${spelling}`);
  }
});

test('conditions array rows expose operator', () => {
  const items = automations.inputSchema.properties.conditions.items;
  assert.ok(items.properties.operator, 'conditions[] should document operator');
  assert.ok(items.properties.operator.enum.includes('<'));
});

test('condition schema no longer documents equality-only semantics', () => {
  assert.ok(!/Uses exact match/.test(addCondition.properties.value.description),
    'value description must not claim equality-only matching');
  assert.match(addCondition.properties.operator.description, /Defaults to "=="/);
});
