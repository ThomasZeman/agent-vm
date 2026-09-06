#!/usr/bin/env bash
# Android SDK, one platform, one x86_64 system image, and the "dev" AVD.

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

# Empty means "resolve the newest" - see the resolver below. The image is meant to ship
# current tooling, so latest is the default and a pin is the exception.
: "${ANDROID_API:=}"
: "${ANDROID_BUILD_TOOLS:=}"
: "${CMDLINE_TOOLS_URL:=https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip}"
: "${AVD_NAME:=dev}"
: "${AVD_DEVICE:=pixel_6}"
: "${AVD_RAM_MB:=4096}"

ANDROID_HOME="$HOME/Android/Sdk"

echo "==> emulator runtime dependencies"
# The emulator is an X client with its own audio/GL stack; without these it fails to start
# with linker errors that look nothing like the real problem.
#
# libxcb-cursor0 is the one that is easy to miss: Qt 6.5+ needs it to load the xcb platform
# plugin, and the emulator's bundled Qt reports it as
#   "Could not load the Qt platform plugin xcb ... even though it was found"
# followed by a fatal "no Qt platform plugin could be initialized". Nothing in that names a
# missing package. The headless build never hits it - -no-window skips the UI entirely - so
# it only shows up the first time someone starts a windowed emulator over RDP.
apt_get install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libpulse0 \
    libnss3 \
    libxcomposite1 \
    libxcursor1 \
    libxi6 \
    libxtst6 \
    libasound2t64 \
    libgl1 \
    libc++1 \
    libxcb-cursor0 \
    socat \
    android-sdk-platform-tools-common

echo "==> KVM access for the dev user"
sudo usermod -aG kvm "$USER"

echo "==> bootstrap command line tools"
# Google publishes no stable "latest" URL for this zip, only build-numbered files that age. So
# treat it as a BOOTSTRAP whose only job is to provide a sdkmanager, which then installs the
# current release of itself - the pin costs a download rather than a stale toolchain.
#
# It must unpack somewhere other than cmdline-tools/latest, which is where the real install
# has to land. sdkmanager will not install over an existing directory, and it does not fail
# either: it diverts to cmdline-tools/latest-2, and from then on every sdkmanager and
# avdmanager invocation prints
#   Warning: Observed package id 'cmdline-tools;latest' in inconsistent location
#            '.../cmdline-tools/latest-2' (Expected '.../cmdline-tools/latest')
# once per repository it consults, while PATH still resolves to the stale bootstrap copy in
# latest/ - so the update silently did nothing except ship a second ~130 MB copy in the image.
# Unpacking beside it instead leaves latest/ free for the install below.
BOOTSTRAP_TOOLS="$ANDROID_HOME/cmdline-tools/bootstrap"
mkdir -p "$ANDROID_HOME/cmdline-tools"
curl -fsSL -o /tmp/cmdline-tools.zip "$CMDLINE_TOOLS_URL"
rm -rf /tmp/cmdline-tools "$BOOTSTRAP_TOOLS" "$ANDROID_HOME/cmdline-tools/latest"
mkdir -p /tmp/cmdline-tools
unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools
# The zip unpacks as cmdline-tools/.
mv /tmp/cmdline-tools/cmdline-tools "$BOOTSTRAP_TOOLS"
rm -rf /tmp/cmdline-tools /tmp/cmdline-tools.zip

echo "==> environment (system-wide, so login shells and cloud-init both see it)"
sudo tee /etc/profile.d/android.sh >/dev/null <<PROFILE
export ANDROID_HOME="${ANDROID_HOME}"
export ANDROID_SDK_ROOT="${ANDROID_HOME}"
export PATH="\$PATH:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator:\$HOME/bin"
PROFILE
sudo chmod 644 /etc/profile.d/android.sh
# shellcheck disable=SC1091
source /etc/profile.d/android.sh

# The BUILD is driven by the bootstrap sdkmanager from here on, and only the image's copy of
# cmdline-tools is "latest". That split is deliberate.
#
# cmdline-tools 23.0 - the current "latest" - no longer ships the Java sdkmanager at all.
# bin/sdkmanager is now a shell shim that announces "The SDK Manager CLI tool (sdkmanager) is
# deprecated" and forwards to a new native `android` CLI, which:
#
#   * downloads itself on first run ("Downloading Android CLI...") and prints a Terms of
#     Service and telemetry banner,
#   * lists packages as slash-separated, column-aligned rows -
#         system-images/android-36/google_apis/x86_64   7.0.0   Google APIs Intel x86_64 ...
#     not the ";"-separated "package | version | description | location" table parsed below,
#   * makes --licenses a no-op ("Warning: The --licenses option is no longer needed."), and
#   * exits NON-ZERO after a successful list: 127 on Linux, a 0xC0000409 crash on Windows.
#
# The first of those already cost a build. The resolver below found nothing in the new format,
# grep exited 1, `set -o pipefail` failed the pipeline, and because the pipeline was the right
# hand side of an assignment, `set -e` killed the script inside the command substitution -
# before the guard that would have said so. All 16 minutes of it ended with "==> resolving the
# newest API with a google_apis x86_64 system image" as the last line and no error.
#
# The bootstrap is a pinned zip, so its sdkmanager is a Java one whose output format is fixed
# by the pin rather than by whatever Google shipped this month. So resolve and install through
# it, and install cmdline-tools;latest at the very end, once nothing left in the build has to
# parse a package list. The image still ships current tooling; only the build stops depending
# on it.
#
# Called by path, never through PATH: PATH already points at latest/bin, which does not exist
# yet. --sdk_root is belt and braces - sdkmanager infers the root from its own location, and
# bootstrap/ sits at the same depth as latest/, so it would infer the same answer.
SDKMANAGER="$BOOTSTRAP_TOOLS/bin/sdkmanager"

echo "==> accepting SDK licences"
# `yes | sdkmanager --licenses` is the incantation every guide prints, and under
# `set -o pipefail` it fails the build even when the licences are accepted perfectly.
# sdkmanager reads the handful of "y" answers it wants and exits 0; `yes` then writes into
# a closed pipe, dies of SIGPIPE, and pipefail reports the pipeline as 128+13 = 141 - which
# arrives as "Script exited with non-zero exit status: 141" with no other diagnostic,
# nineteen minutes into the build. A here-string is not a pipeline, so there is no second
# process whose death can fail the script. Android asks for ~7 licences; 100 answers is
# room to spare, and unread lines are simply discarded when sdkmanager closes stdin.
"$SDKMANAGER" --sdk_root="$ANDROID_HOME" --licenses >/dev/null <<< "$(printf 'y\n%.0s' $(seq 100))"

# `sdkmanager --list` prints "package | version | description | location" over several
# sections. Squeezing out spaces and taking the first column gives bare package ids to match
# against; anchoring the pattern with $ is what rejects previews and release candidates
# ("build-tools;36.0.0-rc1", "platforms;android-VanillaIceCream"), which are exactly what you
# do not want a golden image built against.
sdk_packages() {
    "$SDKMANAGER" --sdk_root="$ANDROID_HOME" --list 2>/dev/null | tr -d ' ' | cut -d'|' -f1
}

# Every resolver below ends in `|| true`, and every one is followed by a guard that reports
# what went wrong. Without it an empty result is a grep exit of 1, and under `set -e` the
# script dies at the assignment - the guard is unreachable and the build ends on the echo
# above it. `|| true` is what makes these diagnostics reachable at all.

if [ -z "$ANDROID_API" ]; then
    echo "==> resolving the newest API with a google_apis x86_64 system image"
    # Deliberately keyed on the SYSTEM IMAGE, not on the platform. Google ships a new
    # platform before the matching emulator image, so "newest platform" periodically names an
    # API with nothing bootable - the SDK install succeeds and then avdmanager fails with
    # "package not available", 20 minutes later. The newest API that can actually boot is the
    # only one worth building an AVD from.
    ANDROID_API="$(sdk_packages \
        | grep -E '^system-images;android-[0-9]+;google_apis;x86_64$' \
        | cut -d';' -f2 | cut -d- -f2 \
        | sort -n | tail -n1 || true)"
    if [ -z "$ANDROID_API" ]; then
        echo "ERROR: no 'system-images;android-N;google_apis;x86_64' package in sdkmanager --list." >&2
        echo "       Either the repository really has none, or sdkmanager stopped printing the" >&2
        echo "       ';'-separated 'package | version | description' table this parses (that is" >&2
        echo "       what cmdline-tools 23.0 did - see the note above SDKMANAGER). Compare:" >&2
        echo "         $SDKMANAGER --sdk_root=$ANDROID_HOME --list | head -n 20" >&2
        exit 1
    fi
fi

if [ -z "$ANDROID_BUILD_TOOLS" ]; then
    echo "==> resolving the newest stable build-tools for API ${ANDROID_API}"
    # Capped at the resolved API for the same reason the API is keyed on the system image:
    # build-tools majors track API levels (the 36.x line belongs to API 36), and Google ships
    # the next major long before the matching platform and emulator image exist. Taking the
    # newest overall therefore pairs build-tools 37 with API 36 - not broken, but no AGP will
    # select it, so the first project build downloads the right one anyway and the ~100 MB in
    # the image is dead weight. Capping keeps the two halves of the SDK on the same release.
    ANDROID_BUILD_TOOLS="$(sdk_packages \
        | grep -E '^build-tools;[0-9]+\.[0-9]+\.[0-9]+$' \
        | cut -d';' -f2 \
        | awk -F. -v api="$ANDROID_API" '$1 <= api' \
        | sort -V | tail -n1 || true)"
    [ -n "$ANDROID_BUILD_TOOLS" ] \
        || { echo "ERROR: no stable build-tools at or below API ${ANDROID_API}" >&2; exit 1; }
fi

SYSTEM_IMAGE="system-images;android-${ANDROID_API};google_apis;x86_64"
echo "    API ${ANDROID_API}, build-tools ${ANDROID_BUILD_TOOLS}"

echo "==> SDK packages (this is the long one: the system image is ~1.5 GB)"
"$SDKMANAGER" --sdk_root="$ANDROID_HOME" --install \
    "platform-tools" \
    "emulator" \
    "platforms;android-${ANDROID_API}" \
    "build-tools;${ANDROID_BUILD_TOOLS}" \
    "$SYSTEM_IMAGE"

echo "==> installing the current command line tools release"
# Last, deliberately: nothing after this parses a package list, so whatever shape the current
# release's sdkmanager has cannot break the build (see the note above SDKMANAGER). It lands in
# cmdline-tools/latest, which is free because the bootstrap was unpacked beside it - see the
# "==> bootstrap command line tools" comment for what happens when it is not.
"$SDKMANAGER" --sdk_root="$ANDROID_HOME" --install "cmdline-tools;latest"
rm -rf "$BOOTSTRAP_TOOLS"

# Fail loudly if it landed anywhere but latest/ - a silent divert is the failure that whole
# dance exists to avoid, and it is much cheaper to catch now than as warnings in a finished
# image.
hash -r
[ -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ] \
    || { echo "ERROR: cmdline-tools;latest did not install into cmdline-tools/latest" >&2; exit 1; }

echo "==> AVD ${AVD_NAME}"
# avdmanager, unlike sdkmanager, is still the classic Java launcher in cmdline-tools 23.0, so
# this is the release just installed and it behaves as it always has. It needs a JDK on PATH
# or JAVA_HOME - 20-node-java.sh installs OpenJDK 21 and points both at it.
# Same reasoning as the licences above: answers on stdin, not through a pipe. ("no" declines
# avdmanager's "do you want to create a custom hardware profile?" prompt.)
avdmanager create avd \
    --name "$AVD_NAME" \
    --package "$SYSTEM_IMAGE" \
    --device "$AVD_DEVICE" \
    --force <<< "no"

avd_config="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
set_cfg() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$avd_config"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$avd_config"
    else
        echo "${key}=${val}" >> "$avd_config"
    fi
}

set_cfg hw.ramSize "$AVD_RAM_MB"
set_cfg vm.heapSize 512
set_cfg disk.dataPartition.size 6G
set_cfg hw.gpu.enabled yes
# No GPU passthrough into Hyper-V Linux guests, so the software rasterizer is the only
# option - and it renders RN UI accurately, which is what matters here.
set_cfg hw.gpu.mode swiftshader_indirect
set_cfg hw.keyboard yes
set_cfg hw.audioInput no
set_cfg hw.audioOutput no
set_cfg showDeviceFrame no

echo "==> adb bridge to the host"
# The emulator publishes its adb port on the guest's LOOPBACK only - 127.0.0.1:5555 - and no
# emulator flag changes that. So "adb connect <vm-ip>:5555" from the Windows host, which is
# the entire point of that port, gets a connection refused: nothing is listening on the
# interface the host can reach.
#
# `adb tcpip 5555` is NOT the fix, despite being the obvious-looking one. It switches the
# guest Android's adbd to TCP mode behind qemu's NAT, which the host still cannot route to -
# and it drops the emulator off the VM's own adb server, so a local `adb exec-out screencap`
# silently returns a zero-byte file until someone restarts the server.
#
# socat republishes the loopback port on the LAN interface, which is all that was ever
# needed. It stays up across emulator restarts: with no emulator running it has nothing to
# forward to and the host's "adb connect" fails exactly as it would have anyway.
#
# It MUST bind the LAN address specifically. `bind=0.0.0.0` looks equivalent and is a disaster
# in two separate ways, both observed:
#
#   1. 0.0.0.0 includes 127.0.0.1, so socat's own listener answers its own forward target.
#      With `fork`, every connection spawns a child that connects straight back into the
#      listener, which forks again - an unbounded fork bomb. Measured: 2050 socat processes,
#      9161 total, load average over 500 on a 4-vCPU guest.
#   2. It takes 127.0.0.1:5555 away from the emulator, which needs exactly that address to
#      publish its own adb port. The emulator then fails or flaps, which reads like a broken
#      snapshot rather than a stolen port.
#
# Binding one address fixes both: loopback:5555 stays free for the emulator, and socat has no
# path back to itself. The address is resolved at start rather than baked in, because it comes
# from DHCP and the image is cloned into many VMs.
sudo tee /usr/local/bin/adb-bridge >/dev/null <<'BRIDGE'
#!/usr/bin/env bash
# Publish the emulator's loopback adb port on this VM's LAN address. See 30-android-sdk.sh.
set -euo pipefail

lan_ip="$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
if [ -z "${lan_ip:-}" ]; then
    echo "adb-bridge: no LAN IPv4 yet; systemd will retry" >&2
    exit 1
fi

echo "adb-bridge: ${lan_ip}:5555 -> 127.0.0.1:5555"
exec socat "TCP-LISTEN:5555,fork,reuseaddr,bind=${lan_ip}" TCP:127.0.0.1:5555
BRIDGE
sudo chmod 755 /usr/local/bin/adb-bridge

sudo tee /etc/systemd/system/adb-bridge.service >/dev/null <<'UNIT'
[Unit]
Description=Publish the emulator's loopback adb port on the LAN interface
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/adb-bridge
Restart=always
RestartSec=5
User=dev

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable adb-bridge.service

echo "==> ~/bin/emu wrapper"
mkdir -p "$HOME/bin"
cat > "$HOME/bin/emu" <<EMU
#!/usr/bin/env bash
# Start the project emulator. Pass -snapshot golden for a warm start (~seconds),
# or -no-snapshot-load to boot cold.
#
# The emulator is windowed by default, and there is no X display for anything started from
# cloud-init, systemd or a plain SSH session - the xrdp X session only exists while someone
# is connected. Started windowed with no display it dies immediately on
#   "Fatal: This application failed to start because no Qt platform plugin could be
#    initialized"
# and whoever launched it is left waiting on an emulator that will never register: at first
# boot that was an \`adb wait-for-device\` blocking cloud-init forever, which also meant the
# tmux session on the next runcmd line never started.
#
# So decide from DISPLAY rather than requiring every caller to remember -no-window. Over RDP
# DISPLAY is set and you get a window; everywhere else it runs headless and adb still works.
args=()
if [ -z "\${DISPLAY:-}" ]; then
    args+=(-no-window)
fi

exec emulator -avd ${AVD_NAME} \\
    -gpu swiftshader_indirect \\
    -no-boot-anim \\
    -no-audio \\
    -no-snapshot-save \\
    -port 5554 "\${args[@]}" "\$@"
EMU
chmod +x "$HOME/bin/emu"

echo "==> versions"
# Print what was actually resolved: with "latest" as the default, the answer is a property of
# the build date, and the only record of it is this line in the build log.
echo "api: ${ANDROID_API}  build-tools: ${ANDROID_BUILD_TOOLS}"
echo "system image: ${SYSTEM_IMAGE}"
# Read the revision off the package rather than running `sdkmanager --version`: in
# cmdline-tools 23.0 that forwards to `android --version`, which downloads the new Android CLI
# on first use, prints a Terms of Service banner, answers "unknown (Android CLI)" if the
# download did not land, and exits non-zero either way - a build failure in a line whose only
# job is to print a version number.
echo "cmdline-tools: $(sed -n 's/^Pkg\.Revision=//p' "$ANDROID_HOME/cmdline-tools/latest/source.properties")"
"$ANDROID_HOME/platform-tools/adb" --version | head -n1

echo "==> 30-android-sdk.sh done"
