/**
 * OpenClaw webhook transform for HomeClaw events.
 *
 * HomeClaw sends payloads with two fields:
 *   text  — Pre-formatted event description, e.g.
 *           "[Garage Door] [Home] HomeKit: Garage Door in Garage power changed to true"
 *   mode  — "now" or "next-heartbeat"
 *
 * Test events send:
 *   { "text": "[HomeClaw] Webhook test event", "mode": "now" }
 *
 * Install: copy to ~/.openclaw/hooks/transforms/homeclaw-transform.js
 */

export function transform(ctx) {
	const { text, mode } = ctx.payload;
	const message = typeof text === 'string' ? text.trim() : '';

	// Test/connectivity events — log silently, don't deliver.
	if (!message || message.includes('Webhook test event')) {
		return {
			action: 'agent',
			message: message || '[HomeClaw] Empty webhook payload',
			name: 'HomeClaw',
			wakeMode: 'now',
			deliver: false,
			channel: 'last'
		};
	}

	return {
		action: 'agent',
		message: `[HomeClaw] ${message}\n\nMonitor this event. Notify the user only for meaningful safety, security, occupancy, or gateway-health changes by using an explicit message tool target; otherwise finish silently.`,
		name: 'HomeClaw',
		wakeMode: mode === 'next-heartbeat' ? 'next-heartbeat' : 'now',
		deliver: false
	};
}
