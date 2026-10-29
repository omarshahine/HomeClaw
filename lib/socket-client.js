import { createConnection } from 'node:net';
import { lstatSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

// App Group container socket (App Store builds) or /tmp fallback (Developer ID).
const APP_GROUP_SOCKET = join(
  homedir(), 'Library', 'Group Containers', 'group.com.shahine.homeclaw', 'homeclaw.sock'
);
const LEGACY_SOCKET = '/tmp/homeclaw.sock';
const TIMEOUT_MS = 30000;

/**
 * Create a client with ordered socket locations. Paths are attempted afresh for
 * every command, so a long-lived MCP process can start before the app or survive
 * a switch between App Store and development builds.
 * @param {string[]} socketPaths - Preferred socket followed by legacy locations
 * @param {number} [timeoutMs=30000] - Inactivity timeout per connection
 * @param {number} [uid=process.getuid()] - Expected owner of socket files
 */
export function createSocketClient(socketPaths, timeoutMs = TIMEOUT_MS, uid = process.getuid()) {
  return function sendCommand(command, args = {}) {
    return new Promise((resolve, reject) => {
      const request = JSON.stringify({ command, args }) + '\n';
      const failures = [];

      function connect(index) {
        const path = socketPaths[index];
        let socket;
        let connected = false;
        let data = '';

        function fail(err) {
          socket?.destroy();
          // Only a failed connect is safe to retry. Once connected, a command
          // may have changed HomeKit even if its response was lost.
          if (!connected && (err.code === 'ENOENT' || err.code === 'ECONNREFUSED')) {
            failures.push(`${path}: ${err.code}`);
            if (index + 1 < socketPaths.length) {
              connect(index + 1);
            } else {
              reject(new Error(
                `Cannot connect to HomeClaw (${failures.join('; ')}). ` +
                'Launch HomeClaw.app first, or restart it if it is already running.'
              ));
            }
          } else {
            reject(err);
          }
        }

        try {
          // In particular, /tmp is shared with other users. Do not follow a
          // symlink or send credentials to a socket another user owns. Once
          // verified, /tmp's sticky bit prevents other users replacing it.
          const info = lstatSync(path);
          if (!info.isSocket() || info.uid !== uid) {
            reject(new Error(`Refusing untrusted HomeClaw socket at ${path}: expected a socket owned by user ${uid}.`));
            return;
          }
          socket = createConnection(path);
        } catch (err) {
          fail(err);
          return;
        }

        socket.setEncoding('utf8');
        socket.on('connect', () => {
          connected = true;
          socket.write(request);
        });
        socket.on('data', (chunk) => { data += chunk; });
        socket.on('end', () => {
          socket.destroy();
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
        socket.on('error', fail);
        socket.setTimeout(timeoutMs, () => {
          socket.destroy();
          reject(new Error('HomeClaw request timed out after ' + (timeoutMs / 1000) + 's'));
        });
      }

      connect(0);
    });
  };
}

/** Send a command to the HomeClaw helper over the Unix domain socket. */
export const sendCommand = createSocketClient([APP_GROUP_SOCKET, LEGACY_SOCKET]);
