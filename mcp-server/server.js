import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { tools } from '../lib/schemas.js';
import {
  handleStatus,
  handleAccessories,
  handleRooms,
  handleScenes,
  handleDeviceMap,
  handleConfig,
} from '../lib/handlers/homekit.js';

const server = new Server(
  { name: 'homeclaw', version: '0.0.1' },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools,
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args = {} } = request.params;

  try {
    let result;

    switch (name) {
      case 'homekit_status':
        result = await handleStatus(args);
        break;
      case 'homekit_accessories':
        result = await handleAccessories(args);
        break;
      case 'homekit_rooms':
        result = await handleRooms(args);
        break;
      case 'homekit_scenes':
        result = await handleScenes(args);
        break;
      case 'homekit_device_map':
        result = await handleDeviceMap(args);
        break;
      case 'homekit_config':
        result = await handleConfig(args);
        break;
      default:
        return {
          content: [{ type: 'text', text: `Unknown tool: ${name}` }],
          isError: true,
        };
    }

    const text = typeof result === 'string' ? result : JSON.stringify(result, null, 2);
    return { content: [{ type: 'text', text }] };
  } catch (error) {
    return {
      content: [{ type: 'text', text: error.message }],
      isError: true,
    };
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
