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
