#!/bin/bash
set -euo pipefail

# HomeClaw — OpenClaw Integration Setup
# Interactive, idempotent setup for the OpenClaw webhook integration.
# Registers the HomeClaw agent, installs the webhook transform,
# configures token auth, and verifies the connection.

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOTAL_STEPS=6

# ─── Helpers ─────────────────────────────────────────────────────────

bold()  { printf "\033[1m%s\033[0m" "$*"; }
green() { printf "\033[32m%s\033[0m" "$*"; }
warn()  { printf "\033[33mWARN:\033[0m %s\n" "$*" >&2; }
error() { printf "\033[31mERROR:\033[0m %s\n" "$*" >&2; }

step() {
    local num="$1" label="$2"
    printf "\n  [%s/%s] %s\n" "$num" "$TOTAL_STEPS" "$(bold "$label")"
}

ok()   { printf "       %s %s\n" "$(green "✓")" "$*"; }
skip() { printf "       %s %s\n" "$(green "–")" "$*"; }
fail() { printf "       \033[31m✗\033[0m %s\n" "$*"; }

# ─── Step 1: Check prerequisites ────────────────────────────────────

check_prereqs() {
    step 1 "Checking prerequisites"

    local missing=0

    if command -v openclaw &>/dev/null; then
        ok "openclaw CLI found: $(command -v openclaw)"
    else
        fail "openclaw CLI not found in PATH"
        missing=1
    fi

    if command -v homeclaw-cli &>/dev/null; then
        ok "homeclaw-cli found: $(command -v homeclaw-cli)"
    else
        fail "homeclaw-cli not found in PATH"
        error "Build and install HomeClaw first: scripts/build.sh --release --install"
        missing=1
    fi

    if [[ -f "$HOME/.openclaw/openclaw.json" ]]; then
        ok "openclaw.json found"
    else
        fail "~/.openclaw/openclaw.json not found"
        error "Run 'openclaw init' first"
        missing=1
    fi

    if [[ "$missing" -ne 0 ]]; then
        error "Missing prerequisites — fix the issues above and re-run."
        exit 1
    fi
}

# ─── Step 2: Register agent ─────────────────────────────────────────

register_agent() {
    step 2 "Registering HomeClaw agent"

    if openclaw agents list 2>/dev/null | grep -q homeclaw; then
        skip "Agent 'homeclaw' already registered"
    else
        local workspace_dir="$PROJECT_ROOT"
        openclaw agents add homeclaw --workspace "$workspace_dir"
        ok "Agent registered (workspace: $workspace_dir)"
    fi

    # Verify
    openclaw agents list 2>/dev/null | grep homeclaw | while IFS= read -r line; do
        printf "       %s\n" "$line"
    done
}

# ─── Step 3: Install webhook transform ──────────────────────────────

install_transform() {
    step 3 "Installing webhook transform"

    local src="$PROJECT_ROOT/openclaw/hooks/homeclaw-transform.js"
    local dest="$HOME/.openclaw/hooks/transforms/homeclaw-transform.js"

    if [[ ! -f "$src" ]]; then
        fail "Transform source not found: $src"
        exit 1
    fi

    mkdir -p "$HOME/.openclaw/hooks/transforms"
    cp "$src" "$dest"
    ok "Installed homeclaw-transform.js (always overwrites with latest)"
}

# ─── Step 4-6: Token and hooks config ───────────────────────────────

configure_webhooks() {
    step 4 "Configuring webhook token"

    local env_file="$HOME/.openclaw/.env"
    local token=""

    # Check for existing token
    if [[ -f "$env_file" ]] && grep -q '^HOMECLAW_WEBHOOK_TOKEN=' "$env_file" 2>/dev/null; then
        token=$(grep '^HOMECLAW_WEBHOOK_TOKEN=' "$env_file" | head -1 | cut -d= -f2-)
        skip "Token already set in ~/.openclaw/.env"
    else
        # Generate a new token
        local generated
        generated=$(openssl rand -base64 24 | tr '+/' '-_' | tr -d '=')
        printf "       Generated token: %s\n" "$(bold "$generated")"
        printf "       Use this token or paste an existing one? [Enter to accept]: "
        read -r user_input
        if [[ -z "$user_input" ]]; then
            token="$generated"
        else
            token="$user_input"
        fi

        # Write to .env
        if [[ -f "$env_file" ]]; then
            echo "HOMECLAW_WEBHOOK_TOKEN=$token" >> "$env_file"
        else
            echo "HOMECLAW_WEBHOOK_TOKEN=$token" > "$env_file"
        fi
        ok "Token written to ~/.openclaw/.env"
    fi

    step 5 "Merging hooks config into openclaw.json"

    local config_file="$HOME/.openclaw/openclaw.json"

    # Use node to merge hooks config without clobbering existing entries
    node -e "
const fs = require('fs');
const configPath = '$config_file';

const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));

// Initialize hooks if missing
if (!config.hooks) config.hooks = {};
config.hooks.enabled = true;
config.hooks.token = '\${HOMECLAW_WEBHOOK_TOKEN}';

// Merge mappings without clobbering existing ones
if (!config.hooks.mappings) config.hooks.mappings = {};
config.hooks.mappings.homeclaw = {
    agentId: 'homeclaw',
    sessionKey: 'hook:homeclaw',
    deliver: true,
    channel: 'last',
    allowUnsafeExternalContent: true
};

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
" || { error "Failed to merge hooks config into openclaw.json"; exit 1; }

    ok "hooks.mappings.homeclaw merged into openclaw.json"
    warn "allowUnsafeExternalContent=true set for local webhooks (127.0.0.1 only)"
}

# ─── Step 5 (continued): Configure HomeClaw ─────────────────────────

configure_homeclaw() {
    step 6 "Configuring HomeClaw webhook endpoint"

    # Read token back from .env
    local env_file="$HOME/.openclaw/.env"
    local token=""
    if [[ -f "$env_file" ]]; then
        token=$(grep '^HOMECLAW_WEBHOOK_TOKEN=' "$env_file" | head -1 | cut -d= -f2-)
    fi

    if [[ -z "$token" ]]; then
        fail "Could not read HOMECLAW_WEBHOOK_TOKEN from ~/.openclaw/.env"
        exit 1
    fi

    homeclaw-cli config --webhook-url "http://127.0.0.1:18789" \
                        --webhook-token "$token" \
                        --webhook-enabled true
    ok "HomeClaw configured to send webhooks to OpenClaw gateway"
}

# ─── Finalize ────────────────────────────────────────────────────────

finalize() {
    printf "\n  %s\n" "$(bold "Restarting OpenClaw gateway...")"
    if openclaw gateway restart 2>/dev/null; then
        ok "Gateway restarted"
    else
        warn "Could not restart gateway (may not be running)"
    fi

    printf "\n  %s\n" "$(bold "Verification")"

    printf "       Agents:\n"
    openclaw agents list 2>/dev/null | while IFS= read -r line; do
        printf "         %s\n" "$line"
    done

    printf "       HomeClaw status:\n"
    homeclaw-cli status 2>/dev/null | while IFS= read -r line; do
        printf "         %s\n" "$line"
    done

    printf "\n  %s\n\n" "$(green "✓ OpenClaw integration setup complete!")"
    printf "  Next steps:\n"
    printf "    1. Ensure HomeClaw.app is running\n"
    printf "    2. Test with: homeclaw-cli config --webhook-test\n"
    printf "    3. Check OpenClaw logs for incoming events\n\n"
}

# ─── Main ────────────────────────────────────────────────────────────

printf "\n  %s\n" "$(bold "HomeClaw — OpenClaw Integration Setup")"
printf "  %s\n" "─────────────────────────────────────────"

check_prereqs
register_agent
install_transform
configure_webhooks
configure_homeclaw
finalize
