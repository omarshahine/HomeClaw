import { createConnection } from 'node:net';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

// App Group container socket (App Store builds) or /tmp fallback (Developer ID).
const APP_GROUP_SOCKET = join(
  homedir(), 'Library', 'Group Containers', 'group.com.shahine.homeclaw', 'homeclaw.sock'
);
const LEGACY_SOCKET = '/tmp/homeclaw.sock';
const SOCKET_PATH = existsSync(APP_GROUP_SOCKET) ? APP_GROUP_SOCKET : LEGACY_SOCKET;
const TIMEOUT_MS = 30000;

/**
 * Send a command to the HomeClaw helper over the Unix domain socket.
 * @param {string} command - Socket command name (e.g. 'list_accessories', 'control')
 * @param {object} [args={}] - Command arguments
 * @returns {Promise<object>} Parsed response data
 */
export function sendCommand(command, args = {}) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(SOCKET_PATH);
    const request = JSON.stringify({ command, args }) + '\n';
    let data = '';

    socket.on('connect', () => socket.write(request));
    socket.on('data', (chunk) => { data += chunk; });
    socket.on('end', () => {
      try {
        const parsed = JSON.parse(data);
        if (!parsed.success) {
          reject(new Error(parsed.error || 'Unknown error from HomeClaw'));
        } else {
          resolve(parsed.data);
        }
      } catch (e) {
        reject(new Error(`Failed to parse response: ${e.message}`));
      }
    });
    socket.on('error', (err) => {
      if (err.code === 'ENOENT') {
        reject(new Error(
          'HomeClaw is not running (socket not found at ' + SOCKET_PATH + '). ' +
          'Launch HomeClaw.app first.'
        ));
      } else if (err.code === 'ECONNREFUSED') {
        reject(new Error(
          'HomeClaw socket exists but connection was refused. Try restarting the app.'
        ));
      } else {
        reject(err);
      }
    });
    socket.setTimeout(TIMEOUT_MS, () => {
      socket.destroy();
      reject(new Error('HomeClaw request timed out after ' + (TIMEOUT_MS / 1000) + 's'));
    });
  });
}
