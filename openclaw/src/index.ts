/**
 * HomeClaw — OpenClaw plugin entry point.
 *
 * Registers tools that shell out to the `homeclaw-cli` binary.
 * Each tool maps to a CLI subcommand (status, list, get, set, scenes, events, etc.).
 */

import { definePluginEntry, type OpenClawPluginDefinition } from 'openclaw/plugin-sdk/plugin-entry';
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
	/**
	 * When true, the tool changes HomeKit state and is opt-in: OpenClaw hides it
	 * until the user allowlists it (e.g. `tools.alsoAllow: ["homeclaw"]`).
	 * Must match `toolMetadata.<name>.optional` in openclaw.plugin.json
	 * (enforced by scripts/check-openclaw-contracts.mjs).
	 */
	optional?: boolean;
}

/**
 * OpenClaw reads `optional` from registerTool's second (options) argument,
 * not from the tool object itself.
 */
function registerOptions(tool: ToolDef): { optional: true } | undefined {
	return tool.optional ? { optional: true } : undefined;
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
						'Narrow to services of this TYPE UUID when the characteristic exists on multiple services. Every channel of a multi-gang switch shares one service type, so use service_name or service_index to pick a channel.',
				})
			),
			service_name: Type.Optional(
				Type.String({
					description:
						'Name or unique UUID of the specific service to write to. This is how you pick one channel of a multi-gang switch; both values appear in the ambiguity error and in homekit_get output.',
				})
			),
			service_id: Type.Optional(
				Type.String({
					description:
						'Unique UUID of the specific service to write to. Use when two services share a name; listed as service_id in the ambiguity error and as `id` per service in homekit_get output.',
				})
			),
			service_index: Type.Optional(
				Type.Number({
					description:
						'Channel number (ServiceLabelIndex) of the specific service to write to, e.g. 1 for the first gang.',
				})
			),
			verify: Type.Optional(
				Type.Boolean({
					description:
						'Default true. After writing, the value is read back and a write the device did not apply comes back as an error rather than a success. Set false only for accessories whose readback is unreliable.',
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
			optionalFlag(args, '--service-name', params.service_name);
			optionalFlag(args, '--service-id', params.service_id);
			optionalFlag(args, '--service-index', params.service_index);
			if (params.verify === false) args.push('--no-verify');
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
			'Rename a HomeKit accessory, or one service (gang) of a multi-service accessory such as the "Switch 2" tile of a dual relay. Use dry_run to preview without applying.',
		parameters: Type.Object({
			accessory: Type.String({
				description:
					'Accessory name or UUID, or a service UUID (the per-service `id` in homekit_get output) to rename just that service',
			}),
			new_name: Type.String({ description: 'New name for the accessory or service' }),
			service_type: Type.Optional(
				Type.String({
					description:
						'Rename only services of this TYPE UUID. Every channel of a multi-gang switch shares one service type, so use service_name or service_index to pick a channel.',
				})
			),
			service_name: Type.Optional(
				Type.String({
					description:
						'Rename only the service with this name or unique UUID, e.g. "Switch 2", instead of the accessory.',
				})
			),
			service_id: Type.Optional(
				Type.String({
					description:
						'Rename only the service with this unique UUID, listed as `id` per service in homekit_get output.',
				})
			),
			service_index: Type.Optional(
				Type.Number({
					description:
						'Rename only the service with this channel number (ServiceLabelIndex), e.g. 2 for the second gang.',
				})
			),
			dry_run: Type.Optional(
				Type.Boolean({ description: 'Preview changes without applying' })
			),
		}),
		buildArgs: (params) => {
			const args = ['rename', String(params.accessory), String(params.new_name)];
			optionalFlag(args, '--service-type', params.service_type);
			optionalFlag(args, '--service-name', params.service_name);
			optionalFlag(args, '--service-id', params.service_id);
			optionalFlag(args, '--service-index', params.service_index);
			optionalFlag(args, '--dry-run', params.dry_run);
			args.push('--json');
			return args;
		},
	},

	{
		name: 'homekit_set_display_as',
		optional: true,
		description:
			'Set the Home app "Display As" of a switch or outlet service: light, fan, or its own type (switch / outlet; "default" restores it). Only switch and outlet services support this. On a multi-gang accessory, pick one gang with service_name, service_index, or service_id. Use dry_run to preview without applying.',
		parameters: Type.Object({
			accessory: Type.String({
				description:
					'Accessory name or UUID, or a service UUID (the per-service `id` in homekit_get output) to target that one service',
			}),
			display_as: Type.Union(
				[
					Type.Literal('light'),
					Type.Literal('fan'),
					Type.Literal('switch'),
					Type.Literal('outlet'),
					Type.Literal('default'),
				],
				{ description: 'What the switch or outlet displays as' }
			),
			service_type: Type.Optional(
				Type.String({ description: 'Narrow to services of this TYPE UUID' })
			),
			service_name: Type.Optional(
				Type.String({
					description: 'Name or unique UUID of the one service to change, e.g. "Switch 2"',
				})
			),
			service_id: Type.Optional(
				Type.String({
					description:
						'Unique UUID of the one service to change, listed as `id` per service in homekit_get output',
				})
			),
			service_index: Type.Optional(
				Type.Number({
					description:
						'Channel number (ServiceLabelIndex) of the one service to change, e.g. 2 for the second gang',
				})
			),
			dry_run: Type.Optional(
				Type.Boolean({ description: 'Preview changes without applying' })
			),
		}),
		buildArgs: (params) => {
			const args = ['set-display-as', String(params.accessory), String(params.display_as)];
			optionalFlag(args, '--service-type', params.service_type);
			optionalFlag(args, '--service-name', params.service_name);
			optionalFlag(args, '--service-id', params.service_id);
			optionalFlag(args, '--service-index', params.service_index);
			optionalFlag(args, '--dry-run', params.dry_run);
			args.push('--json');
			return args;
		},
	},

	// ── Accessory groups ───────────────────────────────────────────────────

	{
		name: 'homekit_groups',
		description:
			'List Home app accessory groups ("Group with Other Accessories") and their member accessories/services. A group shows as one tile in the Home app and is one target for Siri.',
		parameters: Type.Object({}),
		buildArgs: () => ['groups', 'list', '--json'],
	},
	{
		name: 'homekit_manage_group',
		optional: true,
		description:
			'Create, add to, remove from, rename, or delete a Home app accessory group. Members are accessory names/UUIDs, or service UUIDs (per-service `id` in homekit_get) for one gang of a multi-gang accessory. Members must be one kind (lights with lights) unless allow_mixed. Deleting a group leaves its accessories untouched. Use dry_run to preview.',
		parameters: Type.Object({
			action: Type.Union(
				[
					Type.Literal('create'),
					Type.Literal('add'),
					Type.Literal('remove'),
					Type.Literal('rename'),
					Type.Literal('delete'),
				],
				{ description: 'What to do' }
			),
			group: Type.Optional(
				Type.String({
					description: 'Existing group name or UUID (add, remove, rename, delete)',
				})
			),
			name: Type.Optional(Type.String({ description: 'Name for the new group (create)' })),
			members: Type.Optional(
				Type.Array(Type.String(), {
					description: 'Members to create with, add, or remove (create/add/remove)',
				})
			),
			new_name: Type.Optional(Type.String({ description: 'New group name (rename)' })),
			allow_mixed: Type.Optional(
				Type.Boolean({ description: 'Allow members of different kinds (create/add)' })
			),
			dry_run: Type.Optional(
				Type.Boolean({ description: 'Preview changes without applying' })
			),
		}),
		buildArgs: (params) => {
			const action = String(params.action);
			const target = action === 'create' ? params.name : params.group;
			if (!target) throw new Error(action === 'create' ? 'name is required for create' : `group is required for ${action}`);
			const args = ['groups', action];
			if (action === 'create' || action === 'add') {
				optionalFlag(args, '--allow-mixed', params.allow_mixed);
			}
			optionalFlag(args, '--dry-run', params.dry_run);
			args.push('--json');
			// Every positional goes after `--`: group names and members are free text,
			// and one starting with "-" must not be read as a flag.
			args.push('--', String(target));
			if (action === 'rename') {
				if (!params.new_name) throw new Error('new_name is required for rename');
				args.push(String(params.new_name));
			}
			if (action === 'create' || action === 'add' || action === 'remove') {
				const members = Array.isArray(params.members) ? params.members.map(String) : [];
				if (members.length === 0) throw new Error(`members is required for ${action}`);
				args.push(...members);
			}
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

const pluginEntry: OpenClawPluginDefinition = definePluginEntry({
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
					async execute() {
						return toolResult(
							JSON.stringify(
								{ success: false, error: errorMessage },
								null,
								2
							)
						);
					},
				}, registerOptions(tool));
			}
			return;
		}

		for (const tool of TOOLS) {
			api.registerTool({
				name: tool.name,
				label: tool.name,
				description: tool.description,
				parameters: tool.parameters,

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
			}, registerOptions(tool));
		}
	},
});

export default pluginEntry;
