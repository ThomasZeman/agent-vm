#!/usr/bin/env bash
# VS Code and the browsers - the GUI applications the XFCE/xrdp desktop exists to run,
# plus the two ways a project drives a browser without a human at the keyboard.
#
# The desktop from 10-desktop-xrdp.sh is deliberately bare XFCE: no editor and no browser
# come with it. Both are needed here - VS Code to edit the project over RDP, and a browser
# to open the React dev server and its devtools, which is the web equivalent of what the
# emulator does for the native builds. Chrome carries the Claude in Chrome extension so
# Claude Code can drive a real session; Playwright brings its own browser builds for tests.

set -euo pipefail

# sudo runs with env_reset, so an exported DEBIAN_FRONTEND never reaches the apt-get on the
# other side of it - which is what fills the build log with "debconf: unable to initialize
# frontend: Dialog" and two more lines walking down to Teletype. Passing the settings as sudo
# arguments is the form that survives. NEEDRESTART_SUSPEND silences the apt hook that lists
# deferred restarts and outdated sessions: accurate, and meaningless for a machine that is
# about to be shut down and imaged.
apt_get() {
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get "$@"
}

# Empty means "whatever npm resolves as latest" - see the Playwright section below.
: "${PLAYWRIGHT_VERSION:=}"
: "${PLAYWRIGHT_BROWSERS:=chromium firefox webkit}"
# "Claude in Chrome" in the Chrome Web Store. Claude Code needs 1.0.36 or newer, and the
# force-install below always fetches the current release.
: "${CLAUDE_CHROME_EXTENSION_ID:=fcoeoabgfenejglbffodgkkbkcdhcgfn}"

echo "==> VS Code (Microsoft apt repository)"
apt_get install -y wget gpg apt-transport-https
# Keyring in /usr/share/keyrings + signed-by, not the deprecated apt-key.
wget -qO- https://packages.microsoft.com/keys/microsoft.asc     | gpg --dearmor     | sudo tee /usr/share/keyrings/microsoft.gpg >/dev/null
sudo chmod 644 /usr/share/keyrings/microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main"     | sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null
apt_get update
apt_get install -y code

# xdg-utils is what "Open Folder", clicking a link in the terminal, and VS Code's
# "open in browser" all shell out to. Missing, those silently do nothing.
apt_get install -y xdg-utils

echo "==> GitHub CLI (GitHub apt repository)"
# Only the binary. No token, no git identity and no known_hosts entry go into the image;
# New-AgentVM.ps1 logs gh in per VM, after boot, and only when asked. Keyring and list follow
# the layout GitHub documents, which is also what New-AgentVM.ps1's ensure_gh fallback writes
# on an image that predates this step.
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
apt_get update
apt_get install -y gh

echo "==> Google Chrome"
# Chrome as well as Chromium below, for one reason: the Claude in Chrome extension, and
# Claude Code's connection to it. That connection is a native messaging host - a manifest
# in the browser's config directory naming a binary the browser then launches. The
# chromium snap can do neither half reliably: its config lives under ~/snap/chromium
# rather than ~/.config/chromium, and confinement stops it launching Claude Code's binary
# out of /usr/local. Chrome is also what the integration documents as supported, alongside
# Edge and the unconfined Chromium forks.
wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/google-chrome.gpg >/dev/null
sudo chmod 644 /usr/share/keyrings/google-chrome.gpg
# The package's own postinst rewrites this file with an equivalent one on first install.
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
    | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
apt_get update
apt_get install -y google-chrome-stable

echo "==> Claude in Chrome extension (force-installed by policy)"
# There is no unattended "install this extension" command; the supported mechanism is
# enterprise policy, which Chrome reads from /etc/opt/chrome/policies/managed at startup
# and applies to every profile in the guest. The extension then downloads on first launch,
# which is why nothing here can verify more than the policy itself.
#
# No credentials ride along with it. Like Claude Code and the VS Code extension (section
# 10), the extension is signed into nothing in the image: each VM logs in once, and the
# token stays in that guest.
sudo mkdir -p /etc/opt/chrome/policies/managed
sudo tee /etc/opt/chrome/policies/managed/claude-in-chrome.json >/dev/null <<POLICY
{
  "ExtensionInstallForcelist": [
    "${CLAUDE_CHROME_EXTENSION_ID};https://clients2.google.com/service/update2/crx"
  ]
}
POLICY
sudo chmod 644 /etc/opt/chrome/policies/managed/claude-in-chrome.json
# Malformed JSON here is ignored silently by Chrome - no extension, no error anywhere - so
# fail the build instead of shipping an image whose browser tools quietly do not exist.
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' \
    /etc/opt/chrome/policies/managed/claude-in-chrome.json \
    || { echo "ERROR: the Chrome policy file is not valid JSON" >&2; exit 1; }

echo "==> Chromium"
# On 24.04 the chromium-browser deb is a shim that pulls the snap, so this needs snapd to
# be working. Chromium is a convenience for web work, not a build dependency, so a failure
# here is a warning: the image is still usable for React Native and Capacitor.
if ! apt_get install -y chromium-browser; then
    sudo snap install chromium || echo "    chromium unavailable; install it in the VM if you need a browser" >&2
fi

echo "==> Playwright ${PLAYWRIGHT_VERSION:+($PLAYWRIGHT_VERSION) }and its browsers"
# Unlike Chromium above, this is a build dependency - it is how the web side of a project
# gets tested at all - so every step here is fatal rather than a warning.
#
# The browsers are the point of baking this in: `npx playwright install` pulls ~400 MB per
# VM otherwise, on a network the guest may not even have yet. They land in the dev user's
# ~/.cache/ms-playwright, which is where Playwright looks by default - no PLAYWRIGHT_
# BROWSERS_PATH to export, and so nothing that breaks in the profile-less shells that run
# CI-style commands over ssh.
#
# The pairing is version-locked: a project that depends on a different @playwright/test
# than the global one downloads its own browser build into the same cache on first run.
# That is a slower first test run, not a failure, and it is why nothing here pins.
sudo npm install -g "@playwright/test${PLAYWRIGHT_VERSION:+@$PLAYWRIGHT_VERSION}"

# Shared libraries the browser binaries link against - fonts, gtk, gstreamer, and for
# webkit a long tail that no other package on the image pulls in. Root, because it is
# apt-get underneath; the noninteractive settings are the same ones apt_get passes.
# shellcheck disable=SC2086
sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
    playwright install-deps $PLAYWRIGHT_BROWSERS

# Not sudo: run as dev so the cache belongs to dev. Under sudo it would land in root's
# home, where every test run as dev would then fail to find it.
# shellcheck disable=SC2086
playwright install $PLAYWRIGHT_BROWSERS

echo "==> versions"
code --version | head -n1
gh --version | head -n1
google-chrome --version
(chromium --version || chromium-browser --version || echo "chromium: not installed") 2>/dev/null | head -n1
playwright --version
echo "playwright browsers: $(ls "$HOME/.cache/ms-playwright" | tr '\n' ' ')"

echo "==> 25-ide-browser.sh done"
