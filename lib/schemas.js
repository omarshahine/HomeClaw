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
          description: 'Service TYPE UUID to narrow the target when the characteristic exists on multiple services (control action). Note: every channel of a multi-gang switch shares one service type, so this alone cannot pick a channel — use service_name or service_index for that.',
        },
        service_name: {
          type: 'string',
          description: 'Name or unique UUID of the specific service to write to (control action). This is how you pick one channel of a multi-gang switch. Both values are listed in the ambiguity error and in the get action output.',
        },
        service_id: {
          type: 'string',
          description: 'Unique UUID of the specific service to write to (control action). Listed as `service_id` in the ambiguity error and as `id` per service in the get action output. Use this when two services share a name.',
        },
        service_index: {
          type: 'number',
          description: 'Channel number (ServiceLabelIndex) of the specific service to write to, e.g. 1 for the first gang (control action). Listed as `index` in the get action output when the accessory reports one.',
        },
        verify: {
          type: 'boolean',
          description: 'Default true (control action). After writing, the value is read back and a write the device did not apply is returned as an error rather than a success. Set false only for accessories whose readback is unreliable; the response then carries verification_skipped: "disabled".',
        },
        no_refresh: {
          type: 'boolean',
          description: 'Skip live characteristic reads and return last-known + static values only (get action). Much faster and avoids per-call slowdowns when reading many accessories in sequence; safe for static metadata like serial number, model, and firmware.',
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
    description: 'Manage HomeKit structure: rename accessories, assign rooms (with UUID support for duplicate names), create/rename/remove rooms, remove accessories, create/remove zones, and manage zone membership. All actions support dry_run for safe previews.',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: [
            'rename',
            'remove_accessory',
            'assign_rooms',
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
        assignments: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              uuid: { type: 'string', description: 'Accessory UUID (preferred for duplicate names)' },
              accessory: { type: 'string', description: 'Accessory name (fallback, case-insensitive)' },
              room: { type: 'string', description: 'Target room name (created if missing)' },
            },
            required: ['room'],
          },
          description: 'Array of room assignments (assign_rooms action). Each must have "room" plus either "uuid" or "accessory".',
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
    name: 'homekit_automations',
    description: 'Manage HomeKit automations. List existing automations, inspect their events and linked scenes, create automations triggered by any characteristic change (button presses, motion sensors, contact sensors, occupancy, etc.) or by a time of day (clock or sunrise/sunset), delete automations, or enable/disable them. For characteristic-change triggers use action=create with press_type (buttons) or characteristic+trigger_value (sensors). For time-of-day triggers use action=create_time with the `time` field (HH:MM, sunrise, sunset, or <sun-event>±N). Both create actions accept the same predicate vocabulary: weekdays, conditions, time_after, time_before, duration_seconds. Use duration_seconds to auto-revert actions after N seconds (e.g. motion-triggered lights or sunset porch lights that turn off after a delay). Use action=add_condition to append a characteristic condition (ANDed) to an existing automation in place — the trigger UUID is preserved, so button bindings and Siri references survive. List/get also surface HMTimerTrigger automations (Apple Home native time automations) and HMCalendarEvent / HMSignificantTimeEvent / HMDurationEvent details on event triggers; result rows include trigger_type ("button" | "characteristic" | "calendar" | "significant_time" | "timer" | "unknown") and, where applicable, fire_time, fire_date, and duration_seconds. Delete/enable/disable accept any trigger subtype. Note: the predicate-composition features (conditions, time_after/time_before, add_condition) are built on standard HMEventTrigger predicate composition — supported by Apple\'s HomeKit framework APIs but not yet surfaced in the Home app\'s Automations tab. They mirror the rule-editor capabilities exposed by third-party HomeKit apps like Controller for HomeKit. Rules created or modified this way execute correctly via HomeKit; use list/get to inspect them since they may not be editable from the Home app.',
    inputSchema: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['list', 'get', 'create', 'create_time', 'delete', 'enable', 'disable', 'add_condition'],
          description: 'Action to perform. Default: list',
        },
        home_id: {
          type: 'string',
          description: 'Home UUID or name. Defaults to configured home.',
        },
        id: {
          type: 'string',
          description: 'Automation UUID or name (get/delete/enable/disable actions)',
        },
        name: {
          type: 'string',
          description: 'Automation name (create / create_time actions)',
        },
        accessory_id: {
          type: 'string',
          description: 'Trigger accessory UUID or name (create action)',
        },
        time: {
          type: 'string',
          description: 'Time of day the automation fires (create_time action, required). Format: "HH:MM" for a wall-clock time (e.g. "06:30", "17:45"; both fields must be zero-padded two digits — "6:30" is rejected), "sunrise"/"sunset" for sun-relative events, or "<sun-event>±N" where N is minutes (e.g. "sunset-30", "sunrise+15"). Offsets larger than 1440 minutes (24h) are rejected. Implemented as HMCalendarEvent for HH:MM and HMSignificantTimeEvent for sunrise/sunset. All other predicate flags (weekdays, conditions, time_after, time_before, duration_seconds) compose with `time` the same way they do on the create action — `time` is the trigger event, those are the gating predicates.',
        },
        scene_id: {
          type: 'string',
          description: 'Scene UUID or name to trigger (create / create_time actions). Alternative to actions.',
        },
        actions: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              accessory: { type: 'string', description: 'Target accessory UUID (strongly preferred) or name' },
              property: { type: 'string', description: 'Characteristic to set (e.g., power, brightness, color_temperature)' },
              characteristic: { type: 'string', description: 'Alias for "property" — provide one or the other' },
              value: { type: 'string', description: 'Target value as string (e.g., "true", "50", "344")' },
              room: { type: 'string', description: 'Room name for disambiguation (optional)' },
            },
            required: ['accessory', 'value'],
            anyOf: [{ required: ['property'] }, { required: ['characteristic'] }],
          },
          description: 'Inline actions for the automation (create / create_time actions). Alternative to scene_id. Creates a scene named after the automation. Each action sets one characteristic on one accessory.',
        },
        press_type: {
          type: 'number',
          enum: [0, 1, 2],
          description: 'Button press type: 0=single (default), 1=double, 2=long press. For button triggers only; mutually exclusive with characteristic. (create action)',
        },
        characteristic: {
          type: 'string',
          description: 'Characteristic name to trigger on (e.g., motion_detected, contact_state, occupancy_detected, current_temperature). Alternative to press_type for non-button triggers. (create action)',
        },
        trigger_value: {
          type: 'string',
          description: 'Value that triggers the automation (e.g., "true", "false", "1", "0"). Required when characteristic is set. Uses exact value matching. (create action)',
        },
        service_index: {
          type: 'number',
          description: 'Button index for multi-button accessories (1 or 2). For button triggers only. (create action)',
        },
        weekdays: {
          type: 'array',
          items: { type: 'number', enum: [1, 2, 3, 4, 5, 6, 7] },
          description: 'Restrict the automation to fire only on these weekdays (1=Sun, 2=Mon, ..., 7=Sat). When omitted, characteristic-trigger automations (create) fire every day; time-of-day automations (create_time) auto-fill all 7 days since iOS 15+ marks time-conditional automations without weekday gating as "unreliable". Setting time_after/time_before on create with no weekdays also auto-fills all 7 days and sets `weekdays_auto_filled: true` in the response. (create / create_time actions)',
        },
        conditions: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              accessory: { type: 'string', description: 'Condition accessory UUID (preferred) or name' },
              property: { type: 'string', description: 'Characteristic name (e.g., contact_state, occupancy_detected, power)' },
              characteristic: { type: 'string', description: 'Alias for "property" — provide one or the other' },
              value: { type: 'string', description: 'Required value as string (e.g., "true", "0", "50"). Uses exact match (==).' },
              room: { type: 'string', description: 'Room name for accessory disambiguation when multiple accessories share a name (optional)' },
            },
            required: ['accessory', 'value'],
            anyOf: [{ required: ['property'] }, { required: ['characteristic'] }],
          },
          description: 'Extra characteristic predicates ANDed into the trigger predicate. The trigger fires only when the trigger event happens AND every condition holds. Example: porch motion (or sunset, on create_time) that only triggers when the front door is closed AND nobody is home. Each condition is a (characteristic == value) match against any accessory in the home. (create / create_time actions)',
        },
        time_after: {
          type: 'array',
          items: { type: 'string' },
          description: 'Time predicates ANDed into the trigger so it only fires after the given time. Same vocabulary as the `time` field: "HH:MM" for a wall-clock time (zero-padded, e.g. "07:00") or "<sunrise|sunset>[±N]" where N is minutes (e.g., "sunset-30", "sunrise+15", "sunset"). Offsets larger than 1440 minutes are rejected. Combine with time_before for a window (e.g., time_after=["07:00"] + time_before=["20:30"] for "only during the day", or time_after=["sunset-30"] + time_before=["sunrise+15"] for "between dusk and dawn"). On create_time these are gating predicates on top of the `time` trigger event, not the trigger itself. When set without explicit weekdays, HomeClaw auto-fills all 7 days; see the weekdays field. (create / create_time actions)',
        },
        time_before: {
          type: 'array',
          items: { type: 'string' },
          description: 'Time predicates ANDed into the trigger so it only fires before the given time. Same format and offset rules as time_after. (create / create_time actions)',
        },
        duration_seconds: {
          type: 'integer',
          minimum: 1,
          maximum: 86400,
          description: 'Auto-revert the trigger\'s actions after this many seconds (1-86400, i.e. up to 24 hours). Implemented as an HMDurationEvent attached to the trigger\'s endEvents — HomeKit handles the revert natively, no follow-up automation required. Common use cases: motion-triggered lights that should turn off again after a delay (e.g. `duration_seconds: 300` for a 5-minute hold), or sunset porch lights that should turn off after an hour. (create / create_time actions)',
        },
        condition: {
          type: 'object',
          properties: {
            accessory: { type: 'string', description: 'Condition accessory UUID (preferred) or name' },
            property: { type: 'string', description: 'Characteristic name (e.g., contact_state, occupancy_detected, power)' },
            characteristic: { type: 'string', description: 'Alias for "property" — provide one or the other' },
            value: { type: 'string', description: 'Required value as string (e.g., "true", "0", "50"). Uses exact match (==).' },
            room: { type: 'string', description: 'Room name for accessory disambiguation when multiple accessories share a name (optional)' },
          },
          required: ['accessory', 'value'],
          anyOf: [{ required: ['property'] }, { required: ['characteristic'] }],
          description: 'Single characteristic condition (object — note the singular field name, distinct from the plural `conditions` array used by create / create_time) to append (ANDed) to an existing automation\'s trigger predicate. To add multiple conditions, call add_condition repeatedly — each call preserves the trigger UUID, so physical button bindings, Siri references, and other UUID-keyed integrations survive every modification. The read-side decoder (list/get) surfaces the new condition automatically. To replace an existing condition set, delete the automation and recreate it. (add_condition action)',
        },
        dry_run: {
          type: 'boolean',
          description: 'Preview changes without applying (create/create_time/delete/add_condition actions)',
        },
      },
      required: ['action'],
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
