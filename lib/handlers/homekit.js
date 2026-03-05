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
