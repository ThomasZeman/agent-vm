#!/usr/bin/env bash
# XFCE desktop + xrdp, configured for lossless RDP (DESIGN.md, section 6).
#
# The point of the desktop is visual verification: every pixel the guest paints must reach
# the host unchanged, so compression is off and colour depth is pinned to 32 bpp.

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

echo "==> apt update / upgrade"
apt_get update
apt_get -y upgrade

echo "==> XFCE, xrdp and the tools every VM needs"
# Core XFCE, no full Xubuntu application set. This used to be the "xubuntu-core^" tasksel
# TASK, but the subiquity-installed 24.04 server image does not carry that task definition
# in apt's list, so "xubuntu-core^" fails hard with "Couldn't find task 'xubuntu-core'" and
# exit 100. The xfce4 metapackage (universe, enabled by default on 24.04) is a plain package,
# needs no task metadata, and pulls the same session pieces we actually use over xrdp:
# xfce4-session, xfwm4, xfce4-panel, xfdesktop4, xfce4-settings, thunar. No greeter/display
# manager is needed - the xrdp session is launched straight from ~/.xsession below.
apt_get install -y \
    xfce4 \
    xrdp \
    dbus-x11 \
    xfce4-terminal \
    tigervnc-standalone-server \
    tigervnc-tools \
    tmux \
    git \
    jq \
    unzip \
    zip \
    file \
    htop \
    net-tools \
    iproute2

echo "==> xrdp: lossless settings"
# Set a key in [Globals] whether it is present, commented out, or missing entirely.
set_ini() {
    local key="$1" val="$2" file=/etc/xrdp/xrdp.ini
    if grep -qE "^[;#]?[[:space:]]*${key}=" "$file"; then
        sudo sed -i -E "s|^[;#]?[[:space:]]*${key}=.*|${key}=${val}|" "$file"
    else
        sudo sed -i "0,/^\[Globals\]/s//[Globals]\n${key}=${val}/" "$file"
    fi
}

set_ini max_bpp 32
set_ini bitmap_compression false
set_ini bulk_compression false
set_ini new_cursors true
set_ini use_fastpath both

# Drop the lossy codecs so a client cannot negotiate one behind your back. Colours must
# arrive as sent; anything else makes an eyedropper reading meaningless.
sudo sed -i -E 's@^[;#]?[[:space:]]*(rfx_compression|jpeg_compression)=.*@\1=false@' /etc/xrdp/xrdp.ini

# xrdp needs to read the machine's TLS key.
sudo adduser xrdp ssl-cert

echo "==> XFCE as the xrdp session"
echo "xfce4-session" > "$HOME/.xsession"
chmod 644 "$HOME/.xsession"

# light-locker over xrdp is the classic "black screen after reconnect" bug, and a screen
# lock is pointless on a disposable VM behind the host firewall.
apt_get purge -y light-locker || true
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/xfce4-screensaver.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=xfce4-screensaver
Exec=/bin/true
Hidden=true
DESKTOP

# Suppress the polkit prompts xrdp sessions get for colour profiles; they block the desktop
# until dismissed and there is no one at the console to dismiss them.
#
# Use the modern JavaScript .rules format under rules.d/, NOT the legacy .pkla format under
# localauthority/50-local.d/. On Ubuntu 24.04 (polkitd, no pkla-compat) that localauthority
# tree does not exist, so `tee` into it fails with "No such file or directory" and set -e
# aborts the whole build - and even an mkdir'd .pkla would be silently ignored with no
# backend to read it. rules.d/ exists out of the box and is actually honoured.
sudo tee /etc/polkit-1/rules.d/45-allow-colord.rules >/dev/null <<'RULES'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.color-manager.") === 0) {
        return polkit.Result.YES;
    }
});
RULES

echo "==> The agent desktop: one XFCE session on :1 that exists from boot"
# An xrdp login starts a NEW X display for that login, and it is gone again at logout. Nothing
# started before it - cloud-init, systemd, a tmux session opened over SSH - has a display, so
# a headed browser the agent launches either fails ("Missing X server or $DISPLAY") or
# Playwright quietly falls back to headless, and there is nothing to watch.
#
# So the desktop the agent runs in does not wait for anyone to log in. TigerVNC starts it at
# boot as dev on :1, bound to loopback only, and the [Agent] entry in xrdp.ini below makes
# RDP attach to that same display instead of creating one. Closing the RDP window leaves the
# desktop, the agent and its browser running.
echo ":1=dev" | sudo tee /etc/tigervnc/vncserver.users >/dev/null
mkdir -p "$HOME/.vnc" "$HOME/app"
cat > "$HOME/.vnc/config" <<'VNC'
session=xfce
geometry=1920x1080
depth=24
localhost=yes
SecurityTypes=VncAuth
alwaysshared
VNC

# The VNC password is per VM, so it is not in the image: New-AgentVM.ps1 writes ~/.vnc/passwd
# on first boot and starts the unit itself. Until then the condition below makes the unit a
# no-op rather than a failure - which is also what it is during this build.
sudo mkdir -p /etc/systemd/system/tigervncserver@:1.service.d
sudo tee /etc/systemd/system/tigervncserver@:1.service.d/10-agent-vm.conf >/dev/null <<'UNIT'
[Unit]
ConditionPathExists=/home/dev/.vnc/passwd
UNIT
sudo systemctl daemon-reload
sudo systemctl enable tigervncserver@:1

# libvnc ignores the username and checks the password against ~/.vnc/passwd. Listed before
# [Xorg] so it is what the login dialog offers first; [Xorg] stays as the fallback that
# creates a separate desktop per login. With the password saved in Windows Credential
# Manager, mstsc passes it through and the dialog never appears.
if ! grep -q '^\[Agent\]' /etc/xrdp/xrdp.ini; then
    sudo sed -i '0,/^\[Xorg\]/s//[Agent]\
; The persistent desktop on :1 that the agent runs in (tigervncserver@:1).\
name=Agent desktop\
lib=libvnc.so\
username=na\
password=ask\
ip=127.0.0.1\
port=5901\
\
[Xorg]/' /etc/xrdp/xrdp.ini
fi
grep -q '^\[Agent\]' /etc/xrdp/xrdp.ini

# The agent's terminal. tmux keeps the session alive when nobody is watching, and because it
# is started from inside the desktop it inherits DISPLAY=:1, so anything the agent launches
# opens where RDP can see it. `ssh dev@<vm> -t tmux attach -t agent` is a second view of the
# same session.
cat > "$HOME/.config/autostart/agent-terminal.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Agent terminal
Comment=Attaches to the agent tmux session inside the persistent desktop
Exec=xfce4-terminal --title=agent --maximize -x tmux new-session -A -s agent -c /home/dev/app
DESKTOP

# A locked or blanked screen hides the agent from the person watching it. gnome-screensaver
# is masked as well as xfce4-screensaver: a later package pulls it in as a dependency. Xvnc
# has no DPMS, so only the screensaver half of xset applies.
cat > "$HOME/.config/autostart/gnome-screensaver.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=gnome-screensaver
Exec=/bin/true
Hidden=true
DESKTOP
cat > "$HOME/.config/autostart/no-blanking.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=No blanking
Exec=xset s off
DESKTOP

sudo systemctl enable xrdp
sudo systemctl restart xrdp

echo "==> 10-desktop-xrdp.sh done"
