#!/usr/bin/env bash
# Claude Code, the Android MCP server, and the shared conventions file (section 7).
#
# No credentials here, and none injected later either (section 10): each VM authenticates
# once interactively against your Claude subscription, and the token stays in that guest's
# ~/.claude. The image must be login-free - it is shared by every project VM.

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

echo "==> global CLAUDE.md"
mkdir -p "$HOME/shots"
cat > "$HOME/.claude/CLAUDE.md" <<CLAUDEMD
# Conventions for this machine

This is a disposable Ubuntu VM dedicated to one React Native project. The repo is in
\`~/app\`, project-specific environment variables are in \`~/.env\`.

## Emulator

- It is not running unless this VM was created with -StartEmulator; \`adb devices\` tells.
  Start it when the task needs it, warm, in its own tmux window so it outlives your
  command: \`tmux new-window -d -n emu '~/bin/emu -snapshot golden'\` (a few seconds). It
  opens as a window on the desktop the human is watching.
- Cold boot only if the snapshot is broken: \`~/bin/emu -no-snapshot-load\` (60-90 s).
- Check it is up: \`adb devices\` should list \`emulator-5554\` as \`device\`.
- If \`~/.env\` sets \`ADB_SERVER_SOCKET\`, this VM is driving a **physical phone on the
  Windows host** instead. Do not start the emulator; \`adb devices\` already shows the phone.

## The verification loop

Never claim a UI change works because the code looks right. Run the loop:

1. Change the code.
2. Reload Metro: \`adb shell input text RR\` or \`curl -s http://localhost:8081/reload\`.
3. Screenshot: \`adb exec-out screencap -p > ~/shots/\$(date +%H%M%S).png\`.
4. Inspect the screenshot, or use the \`mobile\` MCP tools to read the element tree.
5. Compare against what was asked - colours as hex, spacing in dp
   (px / density; get density with \`adb shell wm density\`).

Screenshots go in \`~/shots/\` so they can be reviewed from the host.

## Preferences

- Prefer the \`mobile\` MCP tools over raw \`adb shell input\` coordinates.
- Metro runs on 8081. If a port is busy, something is already running - check before killing.
- Long-running things (Metro, the emulator, the agent) belong in \`tmux\`, not in a
  foreground shell that dies with the SSH connection.
CLAUDEMD

echo "==> 50-claude.sh done"
