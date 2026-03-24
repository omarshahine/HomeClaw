/**
 * HomeClaw — OpenClaw plugin entry point.
 *
 * Registers tools that shell out to the `homeclaw-cli` binary.
 * Each tool maps to a CLI subcommand (status, list, get, set, scenes, events, etc.).
 */

import { definePluginEntry } from 'openclaw/plugin-sdk/plugin-entry';
import { Type, type TObject } from '@sinclair/typebox';
import { execFile } from 'child_process';
import { promisify } from 'util';
import { existsSync } from 'fs';
import { join } from 'path';

const execFileAsync = promisify(execFile);

interface PluginConfig {
	binDir?: string;
}

interface ToolDef {
	name: string;
	description: string;
	parameters: TObject;
	buildArgs: (params: Record<string, unknown>) => string[];
	/** When true, tool is registered but disabled by default — users opt in via settings. */
	optional?: boolean;
}

/** Helper to build a tool result with the required content + details shape. */
function toolResult(text: string) {
	return {
		content: [{ type: 'text' as const, text }],
		details: undefined,
	};
}

/** Append optional flag arguments. Skips undefined/null/false values. */
function optionalFlag(args: string[], flag: string, value: unknown): void {
	if (value === undefined || value === null || value === false) return;
	if (typeof value === 'boolean') {
		args.push(flag);
	} else {
		args.push(flag, String(value));
	}
}

// ---------------------------------------------------------------------------
// Tool definitions — each maps to a homeclaw-cli subcommand
// ---------------------------------------------------------------------------

const TOOLS: ToolDef[] = [
	// ── Discovery ──────────────────────────────────────────────────────────

	{
		name: 'homekit_status',
		description:
			'Check HomeClaw app and HomeKit connection status. Returns readiness, home count, accessory count, webhook health, and circuit breaker state.',
		parameters: Type.Object({}),
		buildArgs: () => ['status', '--json'],
	},
	{
		name: 'homekit_device_map',
		description:
			'Get an LLM-optimized flat list of all HomeKit devices with display_name, UUID, room, type, controls, and state. This is the primary discovery tool — use it at the start of every session.',
		parameters: Type.Object({
			format: Type.Optional(
				Type.Union(
					[Type.Literal('agent'), Type.Literal('json'), Type.Literal('md')],
					{ description: 'Output format (default: agent)' }
				)
			),
		}),
		buildArgs: (params) => {
			const fmt = String(params.format ?? 'agent');
			const args = ['device-map', '--format', fmt];
			if (fmt === 'json') args.push('--json');
			return args;
		},
	},
	{
		name: 'homekit_list',
		description:
			'List HomeKit accessories, optionally filtered by room or category.',
		parameters: Type.Object({
			room: Type.Optional(Type.String({ description: 'Filter by room name' })),
			category: Type.Optional(
				Type.String({ description: 'Filter by category (e.g., lightbulb, lock)' })
			),
		}),
		buildArgs: (params) => {
			const args = ['list'];
			optionalFlag(args, '--room', params.room);
			optionalFlag(args, '--category', params.category);
			args.push('--json');
			return args;
		},
	},
	{
		name: 'homekit_get',
		description:
			'Get full detail on a single HomeKit accessory including all services, characteristics, and current values.',
		parameters: Type.Object({
			accessory: Type.String({ description: 'Accessory name or UUID' }),
		}),
		buildArgs: (params) => ['get', String(params.accessory), '--json'],
	},
	{
		name: 'homekit_search',
		description:
			'Search HomeKit accessories by name, room, or category. Returns matching devices with basic info.',
		parameters: Type.Object({
			query: Type.String({ description: 'Search query (name, room, or category)' }),
			category: Type.Optional(
				Type.String({ description: 'Filter results by category' })
			),
		}),
		buildArgs: (params) => {
			const args = ['search', String(params.query)];
			optionalFlag(args, '--category', params.category);
			args.push('--json');
			return args;
		},
	},

	// ── Control ────────────────────────────────────────────────────────────

	{
		name: 'homekit_set',
		optional: true,
		description:
			'Control a HomeKit accessory. Set power, brightness, temperature, lock state, blind position, etc. Use UUID for disambiguation when names collide. Use dry_run to validate without actuating.',
		parameters: Type.Object({
			accessory: Type.String({
				description: 'Accessory name or UUID (prefer UUID for disambiguation)',
			}),
			characteristic: Type.String({
				description:
					'Characteristic to set: power, brightness, target_temperature, target_heating_cooling, lock_target_state, target_position',
			}),
			value: Type.String({
				description: 'Value to set (e.g., true, 75, locked, auto)',
			}),
			service_type: Type.Optional(
				Type.String({
					description:
						'Target a specific service by UUID when the characteristic exists on multiple services',
				})
			),
			dry_run: Type.Optional(
				Type.Boolean({ description: 'Validate without writing to the device' })
			),
		}),
		buildArgs: (params) => {
			const args = [
				'set',
				String(params.accessory),
				String(params.characteristic),
				String(params.value),
			];
			optionalFlag(args, '--service-type', params.service_type);
			optionalFlag(args, '--dry-run', params.dry_run);
			args.push('--json');
			return args;
		},
	},

	// ── Scenes ─────────────────────────────────────────────────────────────

	{
		name: 'homekit_scenes',
		description: 'List all HomeKit scenes with names and UUIDs.',
		parameters: Type.Object({}),
		buildArgs: () => ['scenes', '--json'],
	},
	{
		name: 'homekit_get_scene',
		description:
			'Get full detail for a scene including all actions (accessory, room, characteristic, value).',
		parameters: Type.Object({
			scene: Type.String({ description: 'Scene name or UUID' }),
		}),
		buildArgs: (params) => ['get-scene', String(params.scene), '--json'],
	},
	{
		name: 'homekit_trigger',
		optional: true,
		description: 'Execute a HomeKit scene by name or UUID.',
		parameters: Type.Object({
			scene: Type.String({ description: 'Scene name or UUID to trigger' }),
		}),
		buildArgs: (params) => ['trigger', String(params.scene), '--json'],
	},
	{
		name: 'homekit_import_scene',
		optional: true,
		description:
			'Create a new HomeKit scene from a JSON definition file. Use dry_run to preview without creating.',
		parameters: Type.Object({
			file: Type.String({ description: 'Path to JSON file defining the scene' }),
			dry_run: Type.Optional(
				Type.Boolean({ description: 'Preview without creating' })
			),
		}),
		buildArgs: (params) => {
			const args = ['import-scene', String(params.file)];
			optionalFlag(args, '--dry-run', params.dry_run);
			args.push('--json');
			return args;
		},
	},
	{
		name: 'homekit_delete_scene',
		optional: true,
		description:
			'Delete a HomeKit scene by name or UUID. Use dry_run to confirm the scene exists without deleting.',
		parameters: Type.Object({
			scene: Type.String({ description: 'Scene name or UUID' }),
			dry_run: Type.Optional(
				Type.Boolean({ description: 'Preview without deleting' })
			),
		}),
		buildArgs: (params) => {
			const args = ['delete-scene', String(params.scene)];
			optionalFlag(args, '--dry-run', params.dry_run);
			args.push('--json');
			return args;
		},
	},

	// ── Events ─────────────────────────────────────────────────────────────

	{
		name: 'homekit_events',
		description:
			'Query the HomeKit event log. Returns recent characteristic changes, scene triggers, and control actions.',
		parameters: Type.Object({
			since: Type.Optional(
				Type.String({
					description:
						'Show events since (ISO 8601 or duration: 1h, 30m, 2d)',
				})
			),
			type: Type.Optional(
				Type.Union(
					[
						Type.Literal('characteristic_change'),
						Type.Literal('scene_triggered'),
						Type.Literal('accessory_controlled'),
						Type.Literal('homes_updated'),
					],
					{ description: 'Filter by event type' }
				)
			),
			limit: Type.Optional(
				Type.Number({ description: 'Max events to return (default: 50)' })
			),
		}),
		buildArgs: (params) => {
			const args = ['events'];
			optionalFlag(args, '--since', params.since);
			optionalFlag(args, '--type', params.type);
			optionalFlag(args, '--limit', params.limit);
			args.push('--json');
			return args;
		},
	},

	// ── Management ─────────────────────────────────────────────────────────

	{
		name: 'homekit_rename',
		optional: true,
		description:
			'Rename a HomeKit accessory. Use dry_run to preview without applying.',
		parameters: Type.Object({
			accessory: Type.String({ description: 'Accessory name or UUID' }),
			new_name: Type.String({ description: 'New name for the accessory' }),
			dry_run: Type.Optional(
				Type.Boolean({ description: 'Preview changes without applying' })
			),
		}),
		buildArgs: (params) => {
			const args = ['rename', String(params.accessory), String(params.new_name)];
			optionalFlag(args, '--dry-run', params.dry_run);
			args.push('--json');
			return args;
		},
	},

	// ── Automations ────────────────────────────────────────────────────────

	{
		name: 'homekit_automations_list',
		description: 'List all HomeKit automations with names, UUIDs, and enabled state.',
		parameters: Type.Object({}),
		buildArgs: () => ['automations', 'list', '--json'],
	},
	{
		name: 'homekit_automations_get',
		description:
			'Get full detail for a HomeKit automation including trigger, conditions, and actions.',
		parameters: Type.Object({
			id: Type.String({ description: 'Automation name or UUID' }),
		}),
		buildArgs: (params) => ['automations', 'get', String(params.id), '--json'],
	},
	{
		name: 'homekit_automations_create',
		optional: true,
		description:
			'Create a button-press automation that triggers a scene. Use service_index for multi-button accessories.',
		parameters: Type.Object({
			name: Type.String({ description: 'Name for the automation' }),
			accessory: Type.String({
				description: 'Button accessory name or UUID',
			}),
			scene: Type.String({ description: 'Scene name or UUID to trigger' }),
			press: Type.Optional(
				Type.Union(
					[
						Type.Literal('single'),
						Type.Literal('double'),
						Type.Literal('long'),
					],
					{ description: 'Press type (default: single)' }
				)
			),
			service_index: Type.Optional(
				Type.Number({
					description: 'Button index for multi-button accessories (e.g., 0 or 1)',
				})
			),
			dry_run: Type.Optional(
				Type.Boolean({ description: 'Preview without creating' })
			),
		}),
		buildArgs: (params) => {
			const args = [
				'automations',
				'create',
				'--name',
				String(params.name),
				'--accessory',
				String(params.accessory),
				'--scene',
				String(params.scene),
				'--press',
				String(params.press ?? 'single'),
			];
			optionalFlag(args, '--service-index', params.service_index);
			optionalFlag(args, '--dry-run', params.dry_run);
			args.push('--json');
			return args;
		},
	},
];

// ---------------------------------------------------------------------------
// Plugin entry
// ---------------------------------------------------------------------------

/**
 * Resolve homeclaw-cli binary path from plugin config.
 * Default: /Applications/HomeClaw.app/Contents/MacOS/homeclaw-cli
 */
function resolveCliPath(config?: PluginConfig): string {
	const binDir =
		config?.binDir ?? '/Applications/HomeClaw.app/Contents/MacOS';
	const cliPath = join(binDir, 'homeclaw-cli');

	if (existsSync(cliPath)) return cliPath;

	throw new Error(
		`homeclaw-cli not found at ${cliPath}. Install HomeClaw.app or set binDir in plugin config.`
	);
}

export default definePluginEntry({
	id: 'homeclaw',
	name: 'HomeClaw',
	description: 'HomeKit smart home control and monitoring',

	register(api) {
		const config = api.pluginConfig as PluginConfig | undefined;

		let cliPath: string;
		try {
			cliPath = resolveCliPath(config);
		} catch (error) {
			// Defer error to tool execution time — plugin still loads and tools appear
			const errorMessage =
				error instanceof Error ? error.message : String(error);

			for (const tool of TOOLS) {
				api.registerTool({
					name: tool.name,
					label: tool.name,
					description: tool.description,
					parameters: tool.parameters,
					...(tool.optional && { optional: true }),
					async execute() {
						return toolResult(
							JSON.stringify(
								{ success: false, error: errorMessage },
								null,
								2
							)
						);
					},
				});
			}
			return;
		}

		for (const tool of TOOLS) {
			api.registerTool({
				name: tool.name,
				label: tool.name,
				description: tool.description,
				parameters: tool.parameters,
				...(tool.optional && { optional: true }),

				async execute(_id: string, params: Record<string, unknown>) {
					try {
						const args = tool.buildArgs(params);
						const { stdout } = await execFileAsync(cliPath, args, {
							encoding: 'utf8',
							timeout: 30_000,
							maxBuffer: 1024 * 1024,
						});

						let result: unknown;
						try {
							result = JSON.parse(stdout);
						} catch {
							result = { output: stdout.trim() };
						}

						return toolResult(JSON.stringify(result, null, 2));
					} catch (error: unknown) {
						const message =
							error instanceof Error ? error.message : String(error);
						const stderr =
							error && typeof error === 'object' && 'stderr' in error
								? String(
										(error as { stderr: unknown }).stderr
									).trim()
								: '';
						const errorOutput = stderr
							? `${message}\n\nstderr: ${stderr}`
							: message;

						return toolResult(
							JSON.stringify(
								{ success: false, error: errorOutput },
								null,
								2
							)
						);
					}
				},
			});
		}
	},
});
