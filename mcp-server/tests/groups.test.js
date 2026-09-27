import assert from 'node:assert/strict';
import test from 'node:test';
import { handleManage } from '../../lib/handlers/homekit.js';

// Group actions reject bad input before anything is sent to the socket, so an
// agent's malformed call can never reach HomeKit as a partial or empty change.
test('group actions reject missing or malformed members before sending', async () => {
  const bad = [undefined, [], 'Lamp', [''], ['Lamp', 42], [null]];
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
