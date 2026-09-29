#!/usr/bin/env bash
#
# Verify that all plugin version sources agree.
# Exits non-zero if any disagree; prints a table either way.
#
# Note: site/package.json is intentionally independent and excluded.

set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq / apt-get install jq)" >&2
  exit 2
fi

read -r v_root        < <(jq -r '.version'            package.json)
read -r v_openclaw    < <(jq -r '.version'            openclaw/package.json)
read -r v_openclaw_m  < <(jq -r '.version'            openclaw/openclaw.plugin.json)
read -r v_mcp         < <(jq -r '.version'            mcp-server/package.json)
read -r v_cc_plugin   < <(jq -r '.version'            .claude-plugin/plugin.json)
read -r v_cc_market   < <(jq -r '.plugins[0].version' .claude-plugin/marketplace.json)

printf "%-42s %s\n" "File" "Version"
printf "%-42s %s\n" "----" "-------"
printf "%-42s %s\n" "package.json"                     "$v_root"
printf "%-42s %s\n" "openclaw/package.json"            "$v_openclaw"
printf "%-42s %s\n" "openclaw/openclaw.plugin.json"    "$v_openclaw_m"
printf "%-42s %s\n" "mcp-server/package.json"          "$v_mcp"
printf "%-42s %s\n" ".claude-plugin/plugin.json"       "$v_cc_plugin"
printf "%-42s %s\n" ".claude-plugin/marketplace.json"  "$v_cc_market"

all="$v_root $v_openclaw $v_openclaw_m $v_mcp $v_cc_plugin $v_cc_market"
# $all is split on purpose: one version per line.
# shellcheck disable=SC2086
uniq=$(printf '%s\n' $all | sort -u | wc -l | tr -d ' ')

if [ "$uniq" != "1" ]; then
  echo
  echo "FAIL: version sources disagree." >&2
  exit 1
fi

echo
echo "OK: all version sources agree on $v_root"
