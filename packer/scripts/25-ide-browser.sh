#!/usr/bin/env bash
# VS Code and a browser - the two GUI applications the XFCE/xrdp desktop exists to run.
#
# The desktop from 10-desktop-xrdp.sh is deliberately bare XFCE: no editor and no browser
# come with it. Both are needed here - VS Code to edit the project over RDP, and Chromium
# to open the React dev server and its devtools, which is the web equivalent of what the
# emulator does for the native builds.

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
# New-DevVM.ps1 logs gh in per VM, after boot, and only when asked. Keyring and list follow
# the layout GitHub documents, which is also what New-DevVM.ps1's ensure_gh fallback writes
# on an image that predates this step.
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
apt_get update
apt_get install -y gh

echo "==> Chromium"
# On 24.04 the chromium-browser deb is a shim that pulls the snap, so this needs snapd to
# be working. Chromium is a convenience for web work, not a build dependency, so a failure
# here is a warning: the image is still usable for React Native and Capacitor.
if ! apt_get install -y chromium-browser; then
    sudo snap install chromium || echo "    chromium unavailable; install it in the VM if you need a browser" >&2
fi

echo "==> versions"
code --version | head -n1
gh --version | head -n1
(chromium --version || chromium-browser --version || echo "chromium: not installed") 2>/dev/null | head -n1

echo "==> 25-ide-browser.sh done"
