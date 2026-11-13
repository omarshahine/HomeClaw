import assert from 'node:assert/strict';
import test from 'node:test';
import { handleAutomations } from '../../lib/handlers/homekit.js';

function fakeSend() {
  const calls = [];
  const send = async (command, args) => { calls.push([command, args]); return { ok: true }; };
  return { calls, send };
}

const base = { action: 'add_condition', id: 'Porch', condition: { accessory: 'Covelight', property: 'power', value: 'true' } };

// #87: every selector key that is present reaches the socket, explicit null
// included, so SocketServer's strict parser can reject it rather than the
// condition silently landing on the first service.
test('add_condition forwards present service selectors, null included', async () => {
  const { calls, send } = fakeSend();
  await handleAutomations({
    ...base,
    condition: { ...base.condition, service_name: 'Table Light', service_id: null, service_index: 2 },
  }, send);
  assert.equal(calls.length, 1);
  const [command, args] = calls[0];
  assert.equal(command, 'add_automation_condition');
  assert.equal(args.service_name, 'Table Light');
  assert.ok(Object.prototype.hasOwnProperty.call(args, 'service_id'));
  assert.equal(args.service_id, null);
  assert.equal(args.service_index, 2);
});

test('add_condition omits selector keys that are absent', async () => {
  const { calls, send } = fakeSend();
  await handleAutomations(base, send);
  const [, args] = calls[0];
  for (const key of ['service_name', 'service_id', 'service_index']) {
    assert.ok(!Object.prototype.hasOwnProperty.call(args, key), key);
  }
});

// Ordered comparisons (#condition-operators): the operator rides the same wire as the
// value so SocketServer parses and validates it against one canonical list. Forwarded
// verbatim (trimmed) rather than pre-mapped here, so a new spelling only has to be added
// in one place.
test('add_condition forwards a comparison operator', async () => {
  const { calls, send } = fakeSend();
  await handleAutomations({
    ...base,
    condition: { accessory: 'Lux Sensor', property: 'current_light_level', value: '30', operator: ' lt ' },
  }, send);
  assert.equal(calls[0][0], 'add_automation_condition');
  assert.equal(calls[0][1].operator, 'lt');
  assert.equal(calls[0][1].value, '30');
});

test('add_condition omits operator when the condition does not set one', async () => {
  const { calls, send } = fakeSend();
  await handleAutomations(base, send);
  assert.ok(!Object.prototype.hasOwnProperty.call(calls[0][1], 'operator'));
});

// null means "not provided" here, in SocketServer and in the app's native handler alike.
test('add_condition treats a null operator as absent', async () => {
  const { calls, send } = fakeSend();
  await handleAutomations({ ...base, condition: { ...base.condition, operator: null } }, send);
  assert.ok(!Object.prototype.hasOwnProperty.call(calls[0][1], 'operator'));
});

test('add_condition rejects a non-string or empty operator', async () => {
  for (const operator of ['', '   ', 5, {}]) {
    const { send } = fakeSend();
    await assert.rejects(
      () => handleAutomations({ ...base, condition: { ...base.condition, operator } }, send),
      /operator/,
    );
  }
});

test('create forwards action and condition rows untouched, selectors included', async () => {
  const { calls, send } = fakeSend();
  const actions = [
    { accessory: 'R', property: 'power', value: 'false', service_index: 1 },
    { accessory: 'R', property: 'power', value: 'false', service_index: null },
  ];
  const conditions = [{ accessory: 'R', property: 'power', value: 'true', service_name: 'Table Light' }];
  await handleAutomations({ action: 'create', name: 'T', accessory_id: 'S', actions, conditions }, send);
  const [command, args] = calls[0];
  assert.equal(command, 'create_automation');
  assert.deepEqual(args.actions, actions);
  assert.deepEqual(args.conditions, conditions);
});

test('edit forwards only the fields given, empty arrays included', async () => {
  const { calls, send } = fakeSend();
  await handleAutomations({ action: 'edit', id: 'Porch', weekdays: [], conditions: [], time_after: ['sunset-30'] }, send);
  const [command, args] = calls[0];
  assert.equal(command, 'edit_automation');
  assert.deepEqual(args.weekdays, []);
  assert.deepEqual(args.conditions, []);
  assert.deepEqual(args.time_after, ['sunset-30']);
  for (const key of ['new_name', 'time', 'time_before', 'duration_seconds', 'clear_duration', 'dry_run']) {
    assert.ok(!Object.prototype.hasOwnProperty.call(args, key), key);
  }
});

test('edit forwards rename, time, duration and dry_run', async () => {
  const { calls, send } = fakeSend();
  await handleAutomations({ action: 'edit', id: 'Porch', new_name: 'Porch at dusk', time: 'sunset', duration_seconds: 600, dry_run: true }, send);
  const [, args] = calls[0];
  assert.equal(args.new_name, 'Porch at dusk');
  assert.equal(args.time, 'sunset');
  assert.equal(args.duration_seconds, '600');
  assert.equal(args.dry_run, 'true');
});

test('edit rejects a call without changes, and duration together with clear_duration', async () => {
  const { send } = fakeSend();
  await assert.rejects(handleAutomations({ action: 'edit', id: 'Porch' }, send), /at least one of/);
  await assert.rejects(
    handleAutomations({ action: 'edit', id: 'Porch', duration_seconds: 60, clear_duration: true }, send),
    /either duration_seconds or clear_duration/,
  );
  await assert.rejects(handleAutomations({ action: 'edit', id: '  ', new_name: 'x' }, send), /id is required/);
});

// create/edit carry the operator on the conditions array itself, so a threshold gate is
// expressible through the batch form and not only through add_condition.
test('create forwards conditions rows with an operator intact', async () => {
  const { calls, send } = fakeSend();
  await handleAutomations({
    action: 'create',
    name: 'Guest Bath Motion Lights',
    accessory_id: 'A1B2C3D4-0000-0000-0000-000000000001',
    characteristic: 'occupancy_detected',
    trigger_value: 'true',
    actions: [{ accessory: 'Guest Bath Vanity', property: 'power', value: 'true' }],
    conditions: [{ accessory: 'Lux Sensor', property: 'current_light_level', value: '30', operator: 'lt' }],
  }, send);
  assert.equal(calls[0][0], 'create_automation');
  assert.deepEqual(calls[0][1].conditions, [
    { accessory: 'Lux Sensor', property: 'current_light_level', value: '30', operator: 'lt' },
  ]);
});

test('edit forwards conditions rows with an operator intact', async () => {
  const { calls, send } = fakeSend();
  await handleAutomations({
    action: 'edit',
    id: 'Guest Bath Motion Lights',
    conditions: [{ accessory: 'Lux Sensor', property: 'current_light_level', value: '30', operator: '<=' }],
  }, send);
  assert.equal(calls[0][0], 'edit_automation');
  assert.equal(calls[0][1].conditions[0].operator, '<=');
});
