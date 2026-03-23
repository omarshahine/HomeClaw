/**
 * MCP tool definitions for HomeClaw.
 * 5 consolidated tools covering all HomeKit operations.
 */

export const tools = [
  {
    name: 'homekit_status',
    description: 'Check HomeClaw status — shows connectivity, home count, and accessory count.',
    inputSchema: {
      type: 'object',
      properties: {},
    },
  },
  {
    name: 'homekit_accessories',
    description: 'Manage HomeKit accessories: list all, get details, search by name/room/category, or control (set characteristic values). Returns only accessories visible under the current filter configuration. Defaults to configured home if home_id not specified.',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['list', 'get', 'search', 'control'],
          description: 'Action to perform. Default: list',
        },
        home_id: {
          type: 'string',
          description: 'Filter by home UUID. Defaults to configured home if not specified.',
        },
        room: {
          type: 'string',
          description: 'Filter by room name (list action only)',
        },
        accessory_id: {
          type: 'string',
          description: 'Accessory UUID or name (get/control actions)',
        },
        query: {
          type: 'string',
          description: 'Search query — matches name, room, category (search action)',
        },
        category: {
          type: 'string',
          description: 'Filter by category e.g. lightbulb, lock, thermostat (search action)',
        },
        characteristic: {
          type: 'string',
          description: 'Characteristic to set e.g. power, brightness, target_temperature (control action)',
        },
        value: {
          type: 'string',
          description: 'Value to set e.g. true, 75, locked (control action)',
        },
        service_type: {
          type: 'string',
          description: 'Service UUID to target when the characteristic exists on multiple services (control action). Required when an ambiguity error is returned.',
        },
      },
    },
  },
  {
    name: 'homekit_rooms',
    description: 'List HomeKit rooms and their accessories. Defaults to configured home if home_id not specified.',
    inputSchema: {
      type: 'object',
      properties: {
        home_id: {
          type: 'string',
          description: 'Filter by home UUID. Defaults to configured home if not specified.',
        },
      },
    },
  },
  {
    name: 'homekit_scenes',
    description: 'List, get details of, or trigger HomeKit scenes (action sets). Defaults to configured home if home_id not specified.',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['list', 'get', 'trigger'],
          description: 'Action to perform. Default: list. "get" returns all actions in the scene.',
        },
        home_id: {
          type: 'string',
          description: 'Filter by home UUID (list/get action). Defaults to configured home if not specified.',
        },
        scene_id: {
          type: 'string',
          description: 'Scene UUID or name (get/trigger action)',
        },
      },
    },
  },
  {
    name: 'homekit_device_map',
    description: 'Get an LLM-optimized device map organized by home/zone/room with semantic types, auto-generated aliases, controllable characteristics, and state summaries. Use this to understand the full device landscape before controlling devices.',
    inputSchema: {
      type: 'object',
      properties: {
        home_id: {
          type: 'string',
          description: 'Filter by home UUID. Defaults to configured home if not specified.',
        },
      },
    },
  },
  {
    name: 'homekit_manage',
    description: 'Manage HomeKit structure: rename accessories, create/rename/remove rooms, remove accessories, create/remove zones, and manage zone membership. All actions support --dry-run for safe previews.',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: [
            'rename',
            'remove_accessory',
            'create_room',
            'rename_room',
            'remove_room',
            'create_zone',
            'remove_zone',
            'add_room_to_zone',
            'remove_room_from_zone',
          ],
          description: 'Management action to perform',
        },
        home_id: {
          type: 'string',
          description: 'Home UUID or name. Defaults to configured home.',
        },
        id: {
          type: 'string',
          description: 'Accessory, room, or zone name/UUID (action-dependent)',
        },
        new_name: {
          type: 'string',
          description: 'New name for rename actions',
        },
        name: {
          type: 'string',
          description: 'Name for create actions (create_room, create_zone)',
        },
        room: {
          type: 'string',
          description: 'Room name/UUID (zone membership actions)',
        },
        zone: {
          type: 'string',
          description: 'Zone name/UUID (zone membership actions)',
        },
        dry_run: {
          type: 'boolean',
          description: 'Preview changes without applying (default: false)',
        },
      },
      required: ['action'],
    },
  },
  {
    name: 'homekit_config',
    description: 'View or update HomeClaw configuration. Set a default home, or configure device filtering to control which accessories are exposed.',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['get', 'set'],
          description: 'Action to perform. Default: get',
        },
        default_home_id: {
          type: 'string',
          description: 'Home UUID or name to set as active home (set action). All commands operate on the active home.',
        },
        accessory_filter_mode: {
          type: 'string',
          enum: ['all', 'allowlist'],
          description: 'Filter mode: "all" exposes every accessory, "allowlist" only exposes selected accessories (set action).',
        },
        allowed_accessory_ids: {
          type: 'array',
          items: { type: 'string' },
          description: 'Array of accessory UUIDs to expose when filter mode is "allowlist" (set action).',
        },
      },
    },
  },
  {
    name: 'homekit_webhook',
    description: 'Manage webhook configuration for pushing HomeKit events to OpenClaw or other services. Actions: setup (configure URL, token, and enable in one step), test (send a test event and show the HTTP response), reset (reset the circuit breaker), status (show webhook health and delivery stats).',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['setup', 'test', 'reset', 'status'],
          description: 'Action to perform. Default: status',
        },
        url: {
          type: 'string',
          description: 'Base gateway URL, e.g. http://127.0.0.1:18789 (setup action). HomeClaw appends /hooks/wake automatically — do NOT include the path.',
        },
        token: {
          type: 'string',
          description: 'Bearer token for webhook authentication (setup action)',
        },
        enabled: {
          type: 'boolean',
          description: 'Enable or disable the webhook (setup action). Default: true',
        },
      },
    },
  },
  {
    name: 'homekit_events',
    description: 'Get recent HomeKit events — characteristic changes, scene triggers, and accessory control actions. Use to understand what happened recently in the home.',
    inputSchema: {
      type: 'object',
      properties: {
        limit: {
          type: 'number',
          description: 'Maximum number of events to return (default: 50)',
        },
        since: {
          type: 'string',
          description: 'ISO 8601 timestamp — only return events after this time',
        },
        type: {
          type: 'string',
          enum: ['characteristic_change', 'homes_updated', 'scene_triggered', 'accessory_controlled'],
          description: 'Filter by event type',
        },
      },
    },
  },
];
