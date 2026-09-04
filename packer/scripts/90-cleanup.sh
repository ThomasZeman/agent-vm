#!/usr/bin/env bash
# Generalize the image. This is the step that decides whether cloning works at all:
# anything machine-specific left here is duplicated into every VM built from the image.

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

echo "==> apt caches"
apt_get -y autoremove --purge
apt_get -y clean
sudo rm -rf /var/lib/apt/lists/*

echo "==> pin clone datasource to NoCloud"
# Faster, quieter boots for the clones: only ever probe the per-VM NoCloud seed that
# New-DevVM.ps1 attaches, instead of walking every datasource cloud-init knows.
#
# This is done HERE, not in the autoinstall config, on purpose. The installer applies its
# `identity` and `ssh` sections through a first-boot cloud-init run in the target; pinning
# the datasource before that run happens redirects it to the attached cidata CD (the
# autoinstall document, which creates no user) and the image ends up with no dev user and
# no SSH key. By the time this script runs, first boot is long done, so the pin only ever
# affects clones - which is all it was ever meant to do.
echo 'datasource_list: [NoCloud, None]' | sudo tee /etc/cloud/cloud.cfg.d/99-nocloud.cfg >/dev/null

echo "==> cloud-init state"
# Without this, cloud-init believes it has already run and ignores the per-VM seed ISO
# that New-DevVM.ps1 attaches - no user, no key, no repo clone.
sudo cloud-init clean --logs --seed
sudo rm -rf /var/lib/cloud/instances /var/lib/cloud/instance

echo "==> machine identity"
# Truncate, do not delete: systemd regenerates a unique id into an existing empty file at
# first boot. Two VMs sharing a machine-id share a DHCP DUID and fight over one lease.
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id

# cloud-init regenerates host keys on first boot; leaving them here would give every VM
# the same identity and set off host-key warnings on the client.
sudo rm -f /etc/ssh/ssh_host_*

echo "==> logs, history, temp"
sudo find /var/log -type f -exec truncate -s 0 {} \;
sudo rm -rf /var/log/journal/* /var/tmp/* /tmp/emulator-build.log
rm -f "$HOME/.bash_history"
history -c 2>/dev/null || true

echo "==> emulator scratch state"
# The AVD's live QEMU state, if any, would resume into a stale session. The golden
# snapshot under snapshots/golden is what we keep.
rm -f "$HOME/.android/avd/"*.avd/*.lock 2>/dev/null || true
rm -rf "$HOME/.android/avd/"*.avd/snapshots/default_boot 2>/dev/null || true
rm -rf "$HOME/.android/cache" "$HOME/.android/adbkey" "$HOME/.android/adbkey.pub"

echo "==> zeroing free space so the VHDX compacts"
sudo fstrim -av || echo "    fstrim unavailable; Optimize-VHD will recover less space"
sync

echo "==> 90-cleanup.sh done - do not boot this image again before exporting it"
