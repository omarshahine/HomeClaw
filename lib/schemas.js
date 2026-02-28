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
    description: 'List or trigger HomeKit scenes (action sets). Defaults to configured home if home_id not specified.',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['list', 'trigger'],
          description: 'Action to perform. Default: list',
        },
        home_id: {
          type: 'string',
          description: 'Filter by home UUID (list action). Defaults to configured home if not specified.',
        },
        scene_id: {
          type: 'string',
          description: 'Scene UUID or name (trigger action)',
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
