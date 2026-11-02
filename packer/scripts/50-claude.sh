#!/usr/bin/env bash
# Claude Code, its VS Code extension and the Android MCP server (DESIGN.md, section 4).
#
# No credentials here (DESIGN.md, section 7). Each VM is logged in after boot against your
# Claude subscription - by New-AgentVM.ps1 over SSH, or with /login in the guest - and the token
# stays in that guest's ~/.claude. The image must be login-free: it is shared by every VM.

set -euo pipefail

: "${AVD_NAME:=dev}"

# shellcheck disable=SC1091
source /etc/profile.d/android.sh

echo "==> Claude Code"
sudo npm install -g @anthropic-ai/claude-code
claude --version

echo "==> Claude Code extension for VS Code"
# The extension is per-user (~/.vscode/extensions), so it has to be installed here as dev,
# not in 25-ide-browser.sh under sudo. The `code` CLI installs from the Marketplace without a
# display, and the extension ships its own Claude Code binary, so nothing else is needed. The
# login is still per VM, same as for the CLI: the extension stores nothing in the image.
code --install-extension anthropic.claude-code --force
code --list-extensions | grep -qx 'anthropic.claude-code' \
    || { echo "    anthropic.claude-code is not installed after 'code --install-extension'" >&2; exit 1; }

echo "==> Android MCP server"
mkdir -p "$HOME/.claude"
# Driving the UI through MCP tools (tap_element, list_elements_on_screen) is far more
# reliable than `adb shell input tap x y` against coordinates the agent guessed.
if ! claude mcp add --scope user mobile -- npx -y @mobilenext/mobile-mcp@latest; then
    echo "    'claude mcp add' failed; writing the config directly" >&2
    config="$HOME/.claude.json"
    [ -f "$config" ] || echo '{}' > "$config"
    tmp="$(mktemp)"
    jq '.mcpServers.mobile = {"command":"npx","args":["-y","@mobilenext/mobile-mcp@latest"]}' \
        "$config" > "$tmp"
    mv "$tmp" "$config"
fi

echo "==> ~/shots"
# Screenshots go here so they can be reviewed from the host. The global ~/.claude/CLAUDE.md is
# not written here but by New-AgentVM.ps1, through the cloud-init seed: it changes more often
# than the image is rebuilt, and an edit should reach the next VM without a 30-50 min build.
mkdir -p "$HOME/shots"

echo "==> 50-claude.sh done"
