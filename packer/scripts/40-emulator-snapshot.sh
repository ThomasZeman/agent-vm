#!/usr/bin/env bash
# Boot the AVD once and save a "golden" snapshot, so a freshly cloned VM has an emulator
# on screen in seconds instead of 60-90 s (section 4).

set -euo pipefail

: "${AVD_NAME:=dev}"

# shellcheck disable=SC1091
source /etc/profile.d/android.sh

# usermod -aG kvm in the previous script does not affect this SSH session - Packer keeps one
# connection open for the whole build. Re-enter with the group applied.
if ! id -nG | tr ' ' '\n' | grep -qx kvm; then
    echo "==> re-entering with the kvm group"
    exec sg kvm -c "bash '$0'"
fi

echo "==> checking hardware acceleration"
if [ ! -e /dev/kvm ]; then
    echo "ERROR: /dev/kvm is missing. The build VM has no nested virtualization." >&2
    echo "       Set enable_virtualization_extensions = true (and enable_dynamic_memory = false)" >&2
    echo "       on the hyperv-iso source, and check the host with:" >&2
    echo "         Get-VMProcessor -VMName <build-vm> | Select ExposeVirtualizationExtensions" >&2
    exit 1
fi
emulator -accel-check

echo "==> cold-booting ${AVD_NAME}"
adb start-server
nohup emulator -avd "$AVD_NAME" \
    -gpu swiftshader_indirect \
    -no-window \
    -no-audio \
    -no-boot-anim \
    -no-snapshot-load \
    -port 5554 \
    > /tmp/emulator-build.log 2>&1 &

adb wait-for-device

echo "==> waiting for sys.boot_completed"
deadline=$(( $(date +%s) + 900 ))
until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
    if [ "$(date +%s)" -gt "$deadline" ]; then
        echo "ERROR: emulator did not finish booting in 15 minutes. Log:" >&2
        tail -n 50 /tmp/emulator-build.log >&2
        exit 1
    fi
    sleep 5
done

# The first boot keeps working for a while after boot_completed (package optimisation,
# GMS setup). Snapshotting mid-storm produces a snapshot that resumes into that same storm.
echo "==> settling"
adb shell 'while [ "$(getprop init.svc.bootanim)" != "stopped" ]; do sleep 2; done'
sleep 30

echo "==> disabling animations (steadier screenshots, faster agent loops)"
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0

echo "==> saving snapshot 'golden'"
adb emu avd snapshot save golden
adb emu kill || true

# Give QEMU a moment to flush the snapshot to disk before Packer moves on.
for _ in $(seq 1 30); do
    pgrep -f "qemu-system-x86_64.*${AVD_NAME}" >/dev/null || break
    sleep 2
done
adb kill-server || true

snapshot_dir="$HOME/.android/avd/${AVD_NAME}.avd/snapshots/golden"
if [ ! -d "$snapshot_dir" ]; then
    echo "ERROR: snapshot was not written to ${snapshot_dir}" >&2
    exit 1
fi
echo "==> snapshot size: $(du -sh "$snapshot_dir" | cut -f1)"

echo "==> 40-emulator-snapshot.sh done"
