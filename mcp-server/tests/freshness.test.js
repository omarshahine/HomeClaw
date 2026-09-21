import assert from 'node:assert/strict';
import test from 'node:test';
import { validateFreshAccessoryPayload } from '../../lib/freshness.js';
import { handleAccessories } from '../../lib/handlers/homekit.js';
function freshPayload(overrides = {}) {
  return {
    refreshed: true,
    read_attempted: 1,
    read_succeeded: 1,
    services: [{ characteristics: [{
      name: 'contact_state',
      value: '0',
      read: { succeeded: true, observed_at: '2026-09-10T14:00:00.125Z' },
    }] }],
    ...overrides,
  };
}
test('accepts only an internally consistent fresh payload', () => {
  assert.equal(validateFreshAccessoryPayload(freshPayload()), true);
  const invalid = [
    freshPayload({ refreshed: false }),
    freshPayload({ read_attempted: 2 }),
    freshPayload({ services: [] }),
    freshPayload({ services: [{ characteristics: [{
      read: { succeeded: true, observed_at: 'bad' },
    }] }] }),
  ];
  for (const payload of invalid) {
    assert.throws(() => validateFreshAccessoryPayload(payload));
  }
});
test('default MCP get rejects a failed live refresh', async () => {
  const send = async () => freshPayload({ refreshed: false, read_succeeded: 0 });
  await assert.rejects(
    handleAccessories({ action: 'get', accessory_id: 'sensor' }, send),
    /live refresh failed/i,
  );
});
test('a failed refresh names the cause', async () => {
  const send = async () => freshPayload({ refreshed: false, read_succeeded: 0, reachable: false });
  await assert.rejects(
    handleAccessories({ action: 'get', accessory_id: 'sensor' }, send),
    /not reachable.*no_refresh/i,
  );
});
test('explicit no_refresh forwards refresh=false and accepts stale data', async () => {
  let observed;
  const stale = {
    refreshed: false, read_attempted: 0, read_succeeded: 0, services: [],
  };
  const send = async (command, args) => {
    observed = { command, args };
    return stale;
  };
  const result = await handleAccessories(
    { action: 'get', accessory_id: 'sensor', no_refresh: true }, send,
  );

  assert.deepEqual(observed, {
    command: 'get_accessory', args: { id: 'sensor', refresh: false },
  });
  assert.equal(result, stale);
});
