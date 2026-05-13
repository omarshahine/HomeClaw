import { sendCommand } from '../socket-client.js';

/**
 * Maps MCP tool calls to HomeClaw socket commands.
 */

export async function handleStatus() {
  return sendCommand('status');
}

export async function handleAccessories(args) {
  const action = args.action || 'list';

  switch (action) {
    case 'list': {
      const socketArgs = {};
      if (args.home_id) socketArgs.home_id = args.home_id;
      if (args.room) socketArgs.room = args.room;
      return sendCommand('list_accessories', socketArgs);
    }

    case 'get': {
      if (!args.accessory_id) throw new Error('accessory_id is required for get action');
      const socketArgs = { id: args.accessory_id };
      if (args.home_id) socketArgs.home_id = args.home_id;
      return sendCommand('get_accessory', socketArgs);
    }

    case 'search': {
      if (!args.query) throw new Error('query is required for search action');
      const socketArgs = { query: args.query };
      if (args.home_id) socketArgs.home_id = args.home_id;
      if (args.category) socketArgs.category = args.category;
      return sendCommand('search', socketArgs);
    }

    case 'control': {
      if (!args.accessory_id) throw new Error('accessory_id is required for control action');
      if (!args.characteristic) throw new Error('characteristic is required for control action');
      if (!args.value) throw new Error('value is required for control action');
      const socketArgs = {
        id: args.accessory_id,
        characteristic: args.characteristic,
        value: args.value,
      };
      if (args.home_id) socketArgs.home_id = args.home_id;
      if (args.service_type) socketArgs.service_type = args.service_type;
      return sendCommand('control', socketArgs);
    }

    default:
      throw new Error(`Unknown accessories action: ${action}`);
  }
}

export async function handleRooms(args) {
  const socketArgs = {};
  if (args.home_id) socketArgs.home_id = args.home_id;
  return sendCommand('list_rooms', socketArgs);
}

export async function handleScenes(args) {
  const action = args.action || 'list';

  switch (action) {
    case 'list': {
      const socketArgs = {};
      if (args.home_id) socketArgs.home_id = args.home_id;
      return sendCommand('list_scenes', socketArgs);
    }

    case 'get': {
      if (!args.scene_id) throw new Error('scene_id is required for get action');
      const socketArgs = { id: args.scene_id };
      if (args.home_id) socketArgs.home_id = args.home_id;
      return sendCommand('get_scene', socketArgs);
    }

    case 'trigger': {
      if (!args.scene_id) throw new Error('scene_id is required for trigger action');
      const socketArgs = { id: args.scene_id };
      if (args.home_id) socketArgs.home_id = args.home_id;
      return sendCommand('trigger_scene', socketArgs);
    }

    default:
      throw new Error(`Unknown scenes action: ${action}`);
  }
}

export async function handleDeviceMap(args) {
  const socketArgs = {};
  if (args.home_id) socketArgs.home_id = args.home_id;
  return sendCommand('device_map', socketArgs);
}

export async function handleAutomations(args) {
  const action = args.action || 'list';

  switch (action) {
    case 'list': {
      const socketArgs = {};
      if (args.home_id) socketArgs.home_id = args.home_id;
      return sendCommand('list_automations', socketArgs);
    }

    case 'get': {
      if (!args.id) throw new Error('id is required for get action');
      const socketArgs = { id: args.id };
      if (args.home_id) socketArgs.home_id = args.home_id;
      return sendCommand('get_automation', socketArgs);
    }

    case 'create_time': {
      if (!args.name) throw new Error('name is required for create_time action');
      if (!args.time || typeof args.time !== 'string' || args.time.trim() === '') {
        throw new Error("time is required for create_time action. Use 'HH:MM' (e.g. '06:30'), 'sunrise', 'sunset', or '<sun-event>±<minutes>' (e.g. 'sunset-30').");
      }
      if (!args.scene_id && (!args.actions || args.actions.length === 0)) {
        throw new Error('Either scene_id or actions array is required for create_time action');
      }
      const socketArgs = {
        name: args.name,
        time: args.time,
      };
      if (args.scene_id) socketArgs.scene_id = args.scene_id;
      if (args.actions) socketArgs.actions = args.actions;
      if (Array.isArray(args.weekdays) && args.weekdays.length > 0) {
        socketArgs.weekdays = args.weekdays;
      }
      if (Array.isArray(args.conditions) && args.conditions.length > 0) {
        socketArgs.conditions = args.conditions;
      }
      if (Array.isArray(args.time_after) && args.time_after.length > 0) {
        socketArgs.time_after = args.time_after;
      }
      if (Array.isArray(args.time_before) && args.time_before.length > 0) {
        socketArgs.time_before = args.time_before;
      }
      if (args.duration_seconds != null) {
        const d = args.duration_seconds;
        if (!Number.isInteger(d) || d < 1 || d > 86400) {
          throw new Error('duration_seconds must be an integer between 1 and 86400 (24 hours)');
        }
        socketArgs.duration_seconds = String(d);
      }
      if (args.home_id) socketArgs.home_id = args.home_id;
      // Accept actual booleans (MCP schema-compliant) and the common stringified
      // form `"true"`. We deliberately do NOT use loose truthy coercion (`if
      // (args.dry_run)`) because that flips the string `"false"` to truthy and
      // would silently real-apply when the caller wanted a dry-run preview. Any
      // value other than the boolean `true` or the exact string `"true"` is
      // ignored — a string `"false"`, missing key, or unrecognized type all fall
      // through to a real apply, which matches the schema-default of `false`.
      if (args.dry_run === true || args.dry_run === 'true') socketArgs.dry_run = 'true';
      return sendCommand('create_time_automation', socketArgs);
    }

    case 'create': {
      if (!args.name) throw new Error('name is required for create action');
      if (!args.accessory_id) throw new Error('accessory_id is required for create action');
      if (!args.scene_id && (!args.actions || args.actions.length === 0)) {
        throw new Error('Either scene_id or actions array is required for create action');
      }
      const socketArgs = {
        name: args.name,
        accessory_id: args.accessory_id,
      };
      if (args.characteristic) {
        if (args.trigger_value == null) throw new Error('trigger_value is required when characteristic is set');
        socketArgs.characteristic = args.characteristic;
        socketArgs.trigger_value = args.trigger_value;
      } else {
        socketArgs.press_type = String(args.press_type ?? 0);
      }
      if (args.scene_id) socketArgs.scene_id = args.scene_id;
      if (args.actions) socketArgs.actions = args.actions;
      if (args.service_index != null) socketArgs.service_index = String(args.service_index);
      if (Array.isArray(args.weekdays) && args.weekdays.length > 0) {
        socketArgs.weekdays = args.weekdays;
      }
      if (Array.isArray(args.conditions) && args.conditions.length > 0) {
        // Pass through; HomeKitManager validates each entry's accessory + characteristic
        // and rejects malformed shapes via ControlError.invalidArgument.
        socketArgs.conditions = args.conditions;
      }
      if (Array.isArray(args.time_after) && args.time_after.length > 0) {
        socketArgs.time_after = args.time_after;
      }
      if (Array.isArray(args.time_before) && args.time_before.length > 0) {
        socketArgs.time_before = args.time_before;
      }
      if (args.duration_seconds != null) {
        const d = args.duration_seconds;
        if (!Number.isInteger(d) || d < 1 || d > 86400) {
          throw new Error('duration_seconds must be an integer between 1 and 86400 (24 hours)');
        }
        socketArgs.duration_seconds = String(d);
      }
      if (args.home_id) socketArgs.home_id = args.home_id;
      // See create_time above for why we accept the stringified `"true"` too.
      if (args.dry_run === true || args.dry_run === 'true') socketArgs.dry_run = 'true';
      return sendCommand('create_automation', socketArgs);
    }

    case 'delete': {
      if (!args.id) throw new Error('id is required for delete action');
      const socketArgs = { id: args.id };
      if (args.home_id) socketArgs.home_id = args.home_id;
      if (args.dry_run === true || args.dry_run === 'true') socketArgs.dry_run = 'true';
      return sendCommand('delete_automation', socketArgs);
    }

    case 'enable':
    case 'disable': {
      if (!args.id) throw new Error('id is required for enable/disable action');
      const socketArgs = {
        id: args.id,
        enabled: String(action === 'enable'),
      };
      if (args.home_id) socketArgs.home_id = args.home_id;
      return sendCommand('enable_automation', socketArgs);
    }

    case 'add_condition': {
      // Modify-in-place verb: appends a single characteristic condition to an existing
      // automation's trigger predicate. Uses the singular `condition` object (vs the
      // plural `conditions` array on `create`) so the wire shape advertises that this
      // is a single-step append, not a bulk replace.
      // Symmetric whitespace-trim rejection across all required string args
      // — matches the CLI `validate()` and the SocketServer-side guard so the same
      // input fails the same way at every layer. `id` was previously checked with
      // truthy `if (!args.id)` which let whitespace-only strings through; tightened
      // to the same `typeof + trim()` shape as accessory/property/value below.
      if (typeof args.id !== 'string' || args.id.trim() === '') {
        throw new Error('id is required for add_condition action (must be a non-empty string)');
      }
      if (!args.condition || typeof args.condition !== 'object') {
        throw new Error('condition object is required for add_condition action');
      }
      const { accessory, property, value, room } = args.condition;
      if (typeof accessory !== 'string' || accessory.trim() === '') {
        throw new Error('condition.accessory is required (must be a non-empty string)');
      }
      if (typeof property !== 'string' || property.trim() === '') {
        throw new Error('condition.property is required (must be a non-empty string)');
      }
      if (typeof value !== 'string' || value.trim() === '') {
        throw new Error('condition.value must be a non-empty string');
      }
      if (room != null && (typeof room !== 'string' || room.trim() === '')) {
        throw new Error('condition.room must be a non-empty string when provided');
      }
      const socketArgs = {
        id: args.id,
        accessory,
        property,
        value,
      };
      // `room` is forwarded to SocketServer / HomeKitManager.addAutomationCondition
      // as a name-scope disambiguator, matching the pattern used by create /
      // create-time conditions when multiple accessories share a name across rooms.
      if (room) socketArgs.room = room;
      if (args.home_id) socketArgs.home_id = args.home_id;
      // See create_time above for why we accept the stringified `"true"` too.
      if (args.dry_run === true || args.dry_run === 'true') socketArgs.dry_run = 'true';
      return sendCommand('add_automation_condition', socketArgs);
    }

    default:
      throw new Error(`Unknown automations action: ${action}`);
  }
}

export async function handleEvents(args) {
  const socketArgs = {};
  if (args.limit) socketArgs.limit = String(args.limit);
  if (args.since) socketArgs.since = args.since;
  if (args.type) socketArgs.type = args.type;
  return sendCommand('events', socketArgs);
}

export async function handleWebhook(args) {
  const action = args.action || 'status';

  switch (action) {
    case 'setup': {
      const socketArgs = {};
      if (args.url) {
        // Auto-strip common suffixes the user might accidentally include
        let url = args.url;
        for (const suffix of ['/hooks/wake', '/hooks/agent', '/hooks']) {
          if (url.endsWith(suffix)) {
            url = url.slice(0, -suffix.length);
            break;
          }
        }
        socketArgs.url = url;
      }
      if (args.token) socketArgs.token = args.token;
      socketArgs.enabled = String(args.enabled !== false); // default true
      const result = await sendCommand('set_webhook', socketArgs);

      // Auto-test the connection after setup
      try {
        const testResult = await sendCommand('webhook_test');
        return { setup: result, test: testResult };
      } catch {
        return { setup: result, test: { error: 'Test failed — HomeClaw may not be running' } };
      }
    }

    case 'test':
      return sendCommand('webhook_test');

    case 'reset':
      return sendCommand('webhook_reset');

    case 'status': {
      const status = await sendCommand('status');
      // Return just the webhook portion
      return status.webhook || { enabled: false };
    }

    default:
      throw new Error(`Unknown webhook action: ${action}`);
  }
}

export async function handleManage(args) {
  const action = args.action;
  if (!action) throw new Error('action is required');

  const dryRun = args.dry_run ?? false;
  const homeID = args.home_id;

  switch (action) {
    case 'rename': {
      if (!args.id) throw new Error('id is required for rename');
      if (!args.new_name) throw new Error('new_name is required for rename');
      const socketArgs = { id: args.id, new_name: args.new_name, dry_run: dryRun };
      if (homeID) socketArgs.home_id = homeID;
      return sendCommand('rename', socketArgs);
    }

    case 'assign_rooms': {
      if (!args.assignments || !Array.isArray(args.assignments) || args.assignments.length === 0) {
        throw new Error('assignments array is required for assign_rooms');
      }
      const socketArgs = { assignments: args.assignments, dry_run: dryRun };
      if (homeID) socketArgs.home = homeID;
      return sendCommand('assign_rooms', socketArgs);
    }

    case 'remove_accessory': {
      if (!args.id) throw new Error('id is required for remove_accessory');
      const socketArgs = { id: args.id, dry_run: dryRun };
      if (homeID) socketArgs.home_id = homeID;
      return sendCommand('remove_accessory', socketArgs);
    }

    case 'create_room': {
      if (!args.name) throw new Error('name is required for create_room');
      const socketArgs = { name: args.name, dry_run: dryRun };
      if (homeID) socketArgs.home_id = homeID;
      return sendCommand('create_room', socketArgs);
    }

    case 'rename_room': {
      if (!args.id) throw new Error('id is required for rename_room');
      if (!args.new_name) throw new Error('new_name is required for rename_room');
      const socketArgs = { id: args.id, new_name: args.new_name, dry_run: dryRun };
      if (homeID) socketArgs.home_id = homeID;
      return sendCommand('rename_room', socketArgs);
    }

    case 'remove_room': {
      if (!args.id) throw new Error('id is required for remove_room');
      const socketArgs = { id: args.id, dry_run: dryRun };
      if (homeID) socketArgs.home_id = homeID;
      return sendCommand('remove_room', socketArgs);
    }

    case 'create_zone': {
      if (!args.name) throw new Error('name is required for create_zone');
      const socketArgs = { name: args.name, dry_run: dryRun };
      if (homeID) socketArgs.home_id = homeID;
      return sendCommand('create_zone', socketArgs);
    }

    case 'remove_zone': {
      if (!args.id) throw new Error('id is required for remove_zone');
      const socketArgs = { id: args.id, dry_run: dryRun };
      if (homeID) socketArgs.home_id = homeID;
      return sendCommand('remove_zone', socketArgs);
    }

    case 'add_room_to_zone': {
      if (!args.room) throw new Error('room is required for add_room_to_zone');
      if (!args.zone) throw new Error('zone is required for add_room_to_zone');
      const socketArgs = { room: args.room, zone: args.zone, dry_run: dryRun };
      if (homeID) socketArgs.home_id = homeID;
      return sendCommand('add_room_to_zone', socketArgs);
    }

    case 'remove_room_from_zone': {
      if (!args.room) throw new Error('room is required for remove_room_from_zone');
      if (!args.zone) throw new Error('zone is required for remove_room_from_zone');
      const socketArgs = { room: args.room, zone: args.zone, dry_run: dryRun };
      if (homeID) socketArgs.home_id = homeID;
      return sendCommand('remove_room_from_zone', socketArgs);
    }

    default:
      throw new Error(`Unknown manage action: ${action}`);
  }
}

export async function handleConfig(args) {
  const action = args.action || 'get';

  switch (action) {
    case 'get':
      return sendCommand('get_config');

    case 'set': {
      const socketArgs = {};
      if (args.default_home_id === '' || args.default_home_id === 'none') {
        socketArgs.default_home_id = '';
      } else if (args.default_home_id) {
        socketArgs.default_home_id = args.default_home_id;
      }
      if (args.accessory_filter_mode) {
        socketArgs.accessory_filter_mode = args.accessory_filter_mode;
      }
      if (args.allowed_accessory_ids && args.allowed_accessory_ids.length > 0) {
        socketArgs.allowed_accessory_ids = args.allowed_accessory_ids;
      }
      return sendCommand('set_config', socketArgs);
    }

    default:
      throw new Error(`Unknown config action: ${action}`);
  }
}
