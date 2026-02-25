/**
 * HomeClaw — OpenClaw plugin entry point.
 *
 * This is a skill-only plugin. The register() hook validates that the
 * homeclaw-cli binary is discoverable and logs the result. All actual
 * HomeKit interaction happens via the skill (SKILL.md) invoking
 * homeclaw-cli directly.
 */

export function register(api: any): void {
  api.log?.('info', 'HomeClaw: registered (skill-only plugin)');
}
