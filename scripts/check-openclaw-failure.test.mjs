// OpenClaw tool failure payloads (#120 review). migrate-actions prints its JSON
// report and then exits nonzero when an apply fails or does not verify; the
// tool must still hand that report (rollback, added, removed) to the agent.
// Every other tool keeps the original { success, error } shape.
//
// Imports the TypeScript source directly (Node strips erasable types).
// Usage: node --test scripts/check-openclaw-failure.test.mjs
import assert from 'node:assert/strict';
import test from 'node:test';

const { TOOLS, failurePayload } = await import('../openclaw/src/index.ts');

function cliError(stdout, stderr = 'Error: migrate-actions: 1 set(s) failed') {
	return Object.assign(new Error('Command failed: homeclaw-cli automations migrate-actions'), { stdout, stderr, code: 1 });
}

const report = {
	mode: 'apply',
	automations: [{ action_sets: [{ rollback: { actions: [{ action_id: 'A' }] }, apply: { status: 'failed', added: ['N'] } }] }],
};

test('opt-in tools keep the JSON report from stdout', () => {
	const payload = failurePayload(cliError(JSON.stringify(report)), true);
	assert.equal(payload.success, false);
	assert.match(payload.error, /stderr: Error: migrate-actions/);
	assert.deepEqual(payload.report, report);
});

test('non-JSON stdout is kept as output', () => {
	const payload = failurePayload(cliError('plain text'), true);
	assert.equal(payload.output, 'plain text');
	assert.equal(payload.report, undefined);
});

test('other tools keep the original shape', () => {
	const payload = failurePayload(cliError(JSON.stringify(report)), false);
	assert.deepEqual(Object.keys(payload).sort(), ['error', 'success']);
});

test('errors without stdout or stderr', () => {
	assert.deepEqual(failurePayload(new Error('boom'), true), { success: false, error: 'boom' });
});

test('only migrate_actions opts in', () => {
	const optedIn = TOOLS.filter((tool) => tool.reportOnFailure).map((tool) => tool.name);
	assert.deepEqual(optedIn, ['homekit_automations_migrate_actions']);
});

test('migrate_actions builds a single --replace-accessory and rejects separators in names', () => {
	const tool = TOOLS.find((t) => t.name === 'homekit_automations_migrate_actions');
	assert.deepEqual(
		tool.buildArgs({ old_accessory: 'OLD', new_accessories: ['A', 'B'], apply: true }),
		['automations', 'migrate-actions', '--replace-accessory', 'OLD=A,B', '--apply', '--json'],
	);
	assert.throws(() => tool.buildArgs({ old_accessory: 'a=b', new_accessories: ['C'] }), /UUID/);
});
