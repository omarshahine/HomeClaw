/**
 * HomeClaw — OpenClaw plugin entry point.
 *
 * This is a skill-only plugin. The register() hook validates that the
 * homeclaw-cli binary is discoverable and logs the result. All actual
 * HomeKit interaction happens via the skill (SKILL.md) invoking
 * homeclaw-cli directly.
 */

import { existsSync } from 'node:fs';
import { join } from 'node:path';

export function register(api: any): void {
  const binDir = api.config?.binDir ?? '/Applications/HomeClaw.app/Contents/MacOS';
  const cliPath = join(binDir, 'homeclaw-cli');

  if (!existsSync(cliPath)) {
    api.log?.('warn', `HomeClaw: homeclaw-cli not found at ${cliPath}. Install HomeClaw.app or set binDir in plugin config.`);
  } else {
    api.log?.('info', `HomeClaw: registered (homeclaw-cli found at ${cliPath})`);
  }
}
