import assert from 'node:assert/strict';
import test from 'node:test';
import { handleManage } from '../../lib/handlers/homekit.js';

// Group actions reject bad input before anything is sent to the socket, so an
// agent's malformed call can never reach HomeKit as a partial or empty change.
test('group actions reject missing or malformed members before sending', async () => {
  const bad = [undefined, [], 'Lamp', [''], [' \t'], ['Lamp', 42], [null]];
  for (const action of ['create_group', 'add_to_group', 'remove_from_group']) {
    for (const members of bad) {
      await assert.rejects(
        handleManage({ action, name: 'G', group: 'G', members }),
        /members must be a non-empty array/,
        `${action} with members=${JSON.stringify(members)}`,
      );
    }
  }
});

test('group actions require their target arguments', async () => {
  await assert.rejects(handleManage({ action: 'create_group', members: ['Lamp'] }), /name is required/);
  await assert.rejects(handleManage({ action: 'add_to_group', members: ['Lamp'] }), /group is required/);
  await assert.rejects(handleManage({ action: 'remove_from_group', members: ['Lamp'] }), /group is required/);
  await assert.rejects(handleManage({ action: 'rename_group', group: 'G' }), /new_name is required/);
  await assert.rejects(handleManage({ action: 'rename_group', new_name: 'H' }), /group is required/);
  await assert.rejects(handleManage({ action: 'delete_group' }), /group is required/);
});

function fakeSend() {
  const calls = [];
  const send = async (command, args) => { calls.push([command, args]); return { ok: true }; };
  return { calls, send };
}

test('create_group sends exactly its own fields, allow_mixed defaulting to false', async () => {
  const { calls, send } = fakeSend();
  await handleManage({ action: 'create_group', name: 'Ceiling', members: ['Lamp', 'ABC'] }, send);
  assert.deepEqual(calls, [['create_group', { name: 'Ceiling', members: ['Lamp', 'ABC'], allow_mixed: false, dry_run: false }]]);
});

test('delete_group and remove_from_group never forward stray fields', async () => {
  // A hallucinated allow_mixed/members/new_name must not reach the socket, least of
  // all on the destructive actions.
  const { calls, send } = fakeSend();
  await handleManage({ action: 'delete_group', group: 'G', allow_mixed: true, members: ['Lamp'], new_name: 'X' }, send);
  await handleManage({ action: 'remove_from_group', group: 'G', members: ['Lamp'], allow_mixed: true }, send);
  assert.deepEqual(calls, [
    ['delete_group', { group: 'G', dry_run: false }],
    ['remove_from_group', { group: 'G', members: ['Lamp'], dry_run: false }],
  ]);
});

test('dry_run and home_id are forwarded; dry_run is never dropped', async () => {
  const { calls, send } = fakeSend();
  await handleManage({ action: 'delete_group', group: 'G', dry_run: true, home_id: 'Cabin' }, send);
  await handleManage({ action: 'add_to_group', group: 'G', members: ['Lamp'], allow_mixed: true, home_id: 'Cabin' }, send);
  await handleManage({ action: 'list_groups', home_id: 'Cabin' }, send);
  assert.deepEqual(calls, [
    ['delete_group', { group: 'G', dry_run: true, home_id: 'Cabin' }],
    ['add_to_group', { group: 'G', members: ['Lamp'], dry_run: false, allow_mixed: true, home_id: 'Cabin' }],
    ['list_groups', { home_id: 'Cabin' }],
  ]);
});

test('a non-boolean dry_run or allow_mixed is rejected, never sent', async () => {
  // Over the socket a string dry_run reads as false, so "yes" would turn a
  // requested preview into a real delete. Nothing may be sent at all.
  const { calls, send } = fakeSend();
  for (const dry_run of ['yes', 'true', 1, 0, null, {}]) {
    await assert.rejects(handleManage({ action: 'delete_group', group: 'G', dry_run }, send), /dry_run must be a boolean/);
  }
  await assert.rejects(handleManage({ action: 'create_group', name: 'G', members: ['Lamp'], allow_mixed: 'yes' }, send), /allow_mixed must be a boolean/);
  assert.deepEqual(calls, []);
});
