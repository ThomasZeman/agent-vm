#!/usr/bin/env bash
# Android SDK, one platform, one x86_64 system image, and the "dev" AVD.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

: "${ANDROID_API:=35}"
: "${ANDROID_BUILD_TOOLS:=35.0.0}"
: "${CMDLINE_TOOLS_URL:=https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip}"
: "${AVD_NAME:=dev}"
: "${AVD_DEVICE:=pixel_6}"
: "${AVD_RAM_MB:=4096}"

SYSTEM_IMAGE="system-images;android-${ANDROID_API};google_apis;x86_64"
ANDROID_HOME="$HOME/Android/Sdk"

echo "==> emulator runtime dependencies"
# The emulator is an X client with its own audio/GL stack; without these it fails to start
# with linker errors that look nothing like the real problem.
sudo apt-get install -y \
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
    socat \
    android-sdk-platform-tools-common

echo "==> KVM access for the dev user"
sudo usermod -aG kvm "$USER"

echo "==> command line tools"
mkdir -p "$ANDROID_HOME/cmdline-tools"
curl -fsSL -o /tmp/cmdline-tools.zip "$CMDLINE_TOOLS_URL"
rm -rf /tmp/cmdline-tools && mkdir -p /tmp/cmdline-tools
unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools
# The zip unpacks as cmdline-tools/; sdkmanager insists on living in <sdk>/cmdline-tools/latest.
rm -rf "$ANDROID_HOME/cmdline-tools/latest"
mv /tmp/cmdline-tools/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest"
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

echo "==> SDK packages (this is the long one: the system image is ~1.5 GB)"
# `yes | sdkmanager --licenses` is the incantation every guide prints, and under
# `set -o pipefail` it fails the build even when the licences are accepted perfectly.
# sdkmanager reads the handful of "y" answers it wants and exits 0; `yes` then writes into
# a closed pipe, dies of SIGPIPE, and pipefail reports the pipeline as 128+13 = 141 - which
# arrives as "Script exited with non-zero exit status: 141" with no other diagnostic,
# nineteen minutes into the build. A here-string is not a pipeline, so there is no second
# process whose death can fail the script. Android asks for ~7 licences; 100 answers is
# room to spare, and unread lines are simply discarded when sdkmanager closes stdin.
sdkmanager --licenses >/dev/null <<< "$(printf 'y\n%.0s' $(seq 100))"
sdkmanager --install \
    "platform-tools" \
    "emulator" \
    "platforms;android-${ANDROID_API}" \
    "build-tools;${ANDROID_BUILD_TOOLS}" \
    "$SYSTEM_IMAGE"

echo "==> AVD ${AVD_NAME}"
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
sudo tee /etc/systemd/system/adb-bridge.service >/dev/null <<'UNIT'
[Unit]
Description=Publish the emulator's loopback adb port on the LAN interface
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:5555,fork,reuseaddr,bind=0.0.0.0 TCP:127.0.0.1:5555
Restart=always
RestartSec=2
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
exec emulator -avd ${AVD_NAME} \\
    -gpu swiftshader_indirect \\
    -no-boot-anim \\
    -no-audio \\
    -no-snapshot-save \\
    -port 5554 "\$@"
EMU
chmod +x "$HOME/bin/emu"

echo "==> versions"
sdkmanager --version
"$ANDROID_HOME/platform-tools/adb" --version | head -n1

echo "==> 30-android-sdk.sh done"
