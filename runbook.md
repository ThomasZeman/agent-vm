# Runbook: every command, host and guest

Companion to `linux-vm-on-windows.md`. Each block is tagged with where it runs.
For what is already installed in a fresh guest, see `golden-image-contents.md`; for every
parameter of the host scripts, `host-scripts.md`.

| Tag | Where | Shell |
|---|---|---|
| **[H]** | Windows host | PowerShell **as Administrator** |
| **[B]** | Packer build VM | bash — run *by Packer*, not typed |
| **[G]** | Project VM guest | bash as `dev` |
| **[P]** | Physical phone | via adb from the host |

Scripts are named, never pathed: `Build-GoldenImage.ps1` runs from `packer\`,
`New-DevVM.ps1`, `Remove-DevVM.ps1`, `Get-DevVMPassword.ps1` and `Set-DevVMPassword.ps1`
from the directory above it.
After any `winget install`, open a **new** elevated shell — `PATH` is only updated for
processes started afterwards.

Paths below assume the default root `C:\Hyper-V`. To put images and VMs somewhere else, set
it once and every script follows:

```powershell
[Environment]::SetEnvironmentVariable('DEVVM_ROOT', 'E:\Hyper-V', 'Machine')   # new shell after this
```

or pass `-Root E:\Hyper-V` to every script — the same value to all of them.

---

## 1. Host preparation (once)

**[H]** Features, then reboot:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
Restart-Computer
```

BIOS: SVM (AMD-V) enabled. Windows 11 22H2+ for nested virt on AMD.

**[H]** Network switch — external, so VMs get LAN DHCP addresses:

```powershell
Get-NetAdapter                                    # find the NIC name
New-VMSwitch -Name "DevSwitch" -NetAdapterName "Ethernet"
```

**[H]** Storage:

```powershell
New-Item -ItemType Directory -Path C:\Hyper-V\golden, C:\Hyper-V\vms -Force
```

~70 GB free on that drive: the 60 GB golden disk plus Packer's export copy. Differencing
children start near zero and grow with what each project writes.

**[H]** Tools:

```powershell
winget install HashiCorp.Packer
winget install Microsoft.PowerShell
winget install Google.PlatformTools           # adb on the host
winget install Microsoft.WindowsADK           # oscdimg: builds both seed ISOs (golden build, and each VM)
# optional: winget install Genymobile.scrcpy
```

**Then close the shell and open a new elevated one.** winget writes `PATH` for future
processes only; in the current session `packer` and `adb` are still "not recognized".

Verify `oscdimg` is where `New-DevVM.ps1` expects it:

```powershell
Test-Path 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
```

**[H]** SSH key (the guest identity for every VM):

```powershell
ssh-keygen -t ed25519 -C "dev@hyperv"
```

No API key anywhere: the agent logs in per VM against your Claude subscription (§4.2).

---

## 2. Golden image build

**[H]** From `packer\`, one command; 30–50 min:

```powershell
.\Build-GoldenImage.ps1
```

What it runs:

```powershell
packer init  .
packer build -var "output_directory=C:/Hyper-V/golden/build" -var "switch_name=DevSwitch" `
             -var "vm_name=golden-ubuntu-rn" .
```

Restarting after an aborted build is safe: an interrupted run leaves the VM
`golden-ubuntu-rn` registered, and the script offers to delete it before building. Answering
no aborts — Packer would only fail on the name collision. `-Force` skips the question,
`-VmName` builds under a different name and leaves the leftover alone.

### 2.1 Install phase — **[B]**, driven by autoinstall

Subiquity consumes `http/user-data.pkrtpl.hcl`, which Packer renders onto a second CD
labelled `cidata`; cloud-init's NoCloud datasource finds it by that label. The typed boot
command therefore carries no URL:

```
linux /casper/vmlinuz autoinstall ---
initrd /casper/initrd
boot
```

If the installer shows its **language menu** instead of installing, the `autoinstall`
directive never took effect. Press `Ctrl+Alt+F2` in the VM console and check both halves:

```bash
cat /proc/cmdline                      # must contain: autoinstall
blkid -L cidata                        # must name a device, e.g. /dev/sr1
```

No `autoinstall` = keystrokes were dropped in GRUB (raise `boot_keygroup_interval`).
No `cidata` = Packer built no seed ISO, i.e. no oscdimg on PATH.

Late commands in the installed system:

```bash
echo 'dev ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/90-dev
chmod 440 /target/etc/sudoers.d/90-dev
echo 'datasource_list: [NoCloud, None]' > /target/etc/cloud/cloud.cfg.d/99-nocloud.cfg
```

### 2.2 `10-desktop-xrdp.sh` — **[B]**

```bash
sudo apt-get update && sudo apt-get -y upgrade
sudo apt-get install -y xubuntu-core^ xrdp dbus-x11 xfce4-terminal tmux git jq unzip zip file htop net-tools iproute2
# /etc/xrdp/xrdp.ini [Globals]: max_bpp=32, bitmap_compression=false, bulk_compression=false,
#                               new_cursors=true, use_fastpath=both, rfx/jpeg compression=false
sudo adduser xrdp ssl-cert
echo "xfce4-session" > ~/.xsession
sudo apt-get purge -y light-locker
sudo systemctl enable xrdp && sudo systemctl restart xrdp
```

### 2.3 `20-node-java.sh` — **[B]**

```bash
sudo apt-get install -y openjdk-17-jdk
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
curl -fsSL -o /tmp/watchman.zip \
  https://github.com/facebook/watchman/releases/download/${WATCHMAN_VERSION}/watchman-${WATCHMAN_VERSION}-linux.zip
unzip -q /tmp/watchman.zip -d /tmp/watchman
sudo cp -a /tmp/watchman/*/bin/* /usr/local/bin/
sudo cp -a /tmp/watchman/*/lib/* /usr/local/lib/
sudo mkdir -p /usr/local/var/run/watchman && sudo chmod 2777 /usr/local/var/run/watchman
```

### 2.4 `30-android-sdk.sh` — **[B]**

```bash
sudo apt-get install -y qemu-kvm libvirt-daemon-system libpulse0 libnss3 libxcomposite1 \
  libxcursor1 libxi6 libxtst6 libasound2t64 libgl1 libc++1 libxcb-cursor0 socat \
  android-sdk-platform-tools-common
sudo usermod -aG kvm "$USER"

curl -fsSL -o /tmp/cmdline-tools.zip https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
unzip -q /tmp/cmdline-tools.zip -d /tmp/cmdline-tools
mv /tmp/cmdline-tools/cmdline-tools ~/Android/Sdk/cmdline-tools/latest

# /etc/profile.d/android.sh: ANDROID_HOME, ANDROID_SDK_ROOT, PATH += cmdline-tools/latest/bin,
#                            platform-tools, emulator, ~/bin
yes | sdkmanager --licenses
sdkmanager --install "platform-tools" "emulator" "platforms;android-35" \
                     "build-tools;35.0.0" "system-images;android-35;google_apis;x86_64"
echo "no" | avdmanager create avd --name dev --package "system-images;android-35;google_apis;x86_64" \
                     --device pixel_6 --force

# ~/.android/avd/dev.avd/config.ini
#   hw.ramSize=4096  vm.heapSize=512  disk.dataPartition.size=6G
#   hw.gpu.enabled=yes  hw.gpu.mode=swiftshader_indirect  hw.keyboard=yes
#   hw.audioInput=no  hw.audioOutput=no  showDeviceFrame=no

# ~/bin/emu
exec emulator -avd dev -gpu swiftshader_indirect -no-boot-anim -no-audio -no-snapshot-save -port 5554 "$@"
```

### 2.5 `40-emulator-snapshot.sh` — **[B]**

```bash
exec sg kvm -c "bash $0"          # the SSH session predates the kvm group membership
emulator -accel-check
adb start-server
nohup emulator -avd dev -gpu swiftshader_indirect -no-window -no-audio -no-boot-anim \
      -no-snapshot-load -port 5554 > /tmp/emulator-build.log 2>&1 &
adb wait-for-device
until [ "$(adb shell getprop sys.boot_completed)" = "1" ]; do sleep 5; done
adb shell 'while [ "$(getprop init.svc.bootanim)" != "stopped" ]; do sleep 2; done'
sleep 30
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
adb emu avd snapshot save golden
adb emu kill
```

### 2.6 `50-claude.sh` — **[B]**

```bash
sudo npm install -g @anthropic-ai/claude-code
code --install-extension anthropic.claude-code   # per-user, so as dev, not root
claude mcp add --scope user mobile -- npx -y @mobilenext/mobile-mcp@latest
mkdir -p ~/shots
# writes ~/.claude/CLAUDE.md (emulator commands, verification loop, screenshot conventions)
```

### 2.7 `90-cleanup.sh` — **[B]**, generalization

```bash
sudo apt-get -y autoremove --purge && sudo apt-get -y clean
sudo rm -rf /var/lib/apt/lists/*
sudo cloud-init clean --logs --seed
sudo rm -rf /var/lib/cloud/instances /var/lib/cloud/instance
sudo truncate -s 0 /etc/machine-id                       # truncate, never delete
sudo rm -f /var/lib/dbus/machine-id
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
sudo rm -f /etc/ssh/ssh_host_*
sudo find /var/log -type f -exec truncate -s 0 {} \;
sudo rm -rf /var/log/journal/* /var/tmp/* ~/.android/cache ~/.android/adbkey*
rm -f ~/.bash_history
sudo fstrim -av && sync
```

Then Packer: `sudo -S shutdown -P now`.

### 2.8 Post-build — **[H]**, done by `Build-GoldenImage.ps1`

```powershell
Move-Item 'C:\Hyper-V\golden\build\Virtual Hard Disks\golden-ubuntu-rn.vhdx' 'C:\Hyper-V\golden\golden-ubuntu-rn.vhdx'
Optimize-VHD -Path C:\Hyper-V\golden\golden-ubuntu-rn.vhdx -Mode Full
Set-ItemProperty C:\Hyper-V\golden\golden-ubuntu-rn.vhdx -Name IsReadOnly -Value $true
Remove-Item C:\Hyper-V\golden\build -Recurse -Force
```

---

## 3. Verify the image once

**[H]**

```powershell
.\New-DevVM.ps1 -Name smoke
```

**[G]** — `ssh dev@<vm-ip>`

```bash
ls -l /dev/kvm && emulator -accel-check
~/bin/emu -snapshot golden &          # on screen in seconds, not 90 s
adb devices                           # emulator-5554  device
node --version && java -version && claude --version
```

**[H]**

```powershell
.\Remove-DevVM.ps1 -Name smoke -Force
```

---

## 4. Create a project VM

**[H]**

```powershell
.\New-DevVM.ps1 -Name app-foo -Repo me/app-foo          # offers your GitHub + Claude logins (4.2, 4.3), clones
.\New-DevVM.ps1 -Name app-foo -Repo me/app-foo -SkipGitHubLogin -SkipClaudeLogin   # no prompts, no credentials, ~/app empty
# phone-backed instead of emulator:
.\New-DevVM.ps1 -Name app-bar -Repo <repo> -DeviceSerial 1A2B3C4D -HostIp 192.168.1.10
```

What it executes:

```powershell
New-VHD -Path C:\Hyper-V\vms\app-foo\disk.vhdx -ParentPath C:\Hyper-V\golden\golden-ubuntu-rn.vhdx -Differencing
New-VM -Name app-foo -Generation 2 -MemoryStartupBytes 10GB -VHDPath C:\Hyper-V\vms\app-foo\disk.vhdx `
       -SwitchName DevSwitch -Path C:\Hyper-V\vms
Set-VM -Name app-foo -StaticMemory -AutomaticStartAction Nothing -AutomaticStopAction Shutdown
Set-VM -Name app-foo -CheckpointType Disabled
Set-VMProcessor -VMName app-foo -Count 4 -ExposeVirtualizationExtensions $true
Set-VMNetworkAdapter -VMName app-foo -MacAddressSpoofing On
Set-VMFirmware -VMName app-foo -EnableSecureBoot Off
oscdimg.exe -n -m -d -lCIDATA <tempdir> C:\Hyper-V\vms\app-foo\seed.iso    # user-data + meta-data
Add-VMDvdDrive -VMName app-foo -Path C:\Hyper-V\vms\app-foo\seed.iso
Set-VMFirmware -VMName app-foo -FirstBootDevice (Get-VMHardDiskDrive -VMName app-foo)
Start-VM -Name app-foo
Get-VMNetworkAdapter -VMName app-foo | Select-Object -ExpandProperty IPAddresses   # polled to DHCP
# writes .\app-foo.rdp
```

### 4.1 First boot — **[G]**, run by cloud-init from the seed ISO

```bash
# user: dev (sudo, kvm), your SSH key, RDP password from chpasswd
# ~/.env: PROJECT, ADB_SERVER_SOCKET, ANDROID_SERIAL   (no credentials)
# No clone and no credentials here: cloud-init runs before anyone can authenticate, so a
# private repo would need a credential on the seed ISO - which stays attached and readable
# in the guest. Credentials and the checkout are SSH steps after boot (4.2, 4.3).
sudo -u dev mkdir -p /home/dev/app
# emulator path only (no DEVICE_SERIAL):
sudo -u dev bash -lc '~/bin/emu -snapshot golden >/tmp/emu.log 2>&1 &'
sudo -u dev bash -lc 'sleep 20 && adb wait-for-device'
sudo -u dev tmux new -d -s agent -c /home/dev/app
```

Watch it: **[G]** `sudo cloud-init status --wait; sudo tail -f /var/log/cloud-init-output.log`

### 4.2 GitHub login and checkout — **[H]**, once per VM

Before building the VM, `New-DevVM.ps1` checks whether `gh` on the host is logged in. If it
is, it prints the account, the token scopes and your global git identity, and asks:

```
  Copy your GitHub login into this VM? [Y/n]
```

Yes: once the guest answers SSH and cloud-init has finished, the script copies
`devvm-setup.sh` to `/tmp` in the guest and pipes the token and identity to it on SSH stdin
(never as an argument, never onto the seed ISO). In the guest that runs
`gh auth login --with-token`, `gh auth setup-git` and `git config --global user.*`; then,
with `-Repo`, it clones into `~/app` and runs `npm install` with no further prompt. The VM
now shares the token with the host — revoking it at github.com/settings/applications logs
both out — and in the guest it sits in `~/.config/gh/hosts.yml` in plain text, as any
headless `gh` login does.

No, or `gh` not logged in on the host: with `-Repo`, the interactive flow is offered at the
end instead:

```
  Log into GitHub in this VM and clone the project now? [Y/n]
```

That runs the same script over `ssh -t`, so `gh auth login`'s one-time-code prompts land in
your terminal, and the VM gets a token of its own.

The golden image carries the `gh` binary and nothing else GitHub-related — no token, no git
identity, no `known_hosts` entry — and no credential is written to the seed ISO, which stays
attached to the VM and is readable from inside it.

`-SkipGitHubLogin` skips both offers and the clone. To do it later, or after answering no:

```powershell
ssh dev@<vm-ip> -t "bash /tmp/devvm-setup.sh clone 'you/foo'"   # the script stays in the guest
ssh -A dev@<vm-ip>                                              # or clone by hand over agent forwarding
```

For a non-GitHub remote, `-Repo` still works: the script falls back to plain `git clone`, and
seeds `known_hosts` for the remote host first if the URL is SSH-form.

### 4.3 Log the agent in — **[H]** at creation, or **[G]** by hand, once per VM

`New-DevVM.ps1` also offers to log Claude Code in, using a long-lived token for your Claude
**subscription** — not an API key, nothing billed per token. The token comes from
`claude setup-token` on the host (a browser login; paste the printed token back into the
script), and is cached at `~\.devvm\claude-oauth-token` (`-ClaudeTokenPath`), readable by
your account only, for every later VM:

```
  Log Claude Code into this VM with it? [Y/n]
```

Yes writes it over SSH after boot into the guest's `~/.claude/settings.json` as
`env.CLAUDE_CODE_OAUTH_TOKEN`. The CLI and the VS Code extension are logged in from their
first launch. That entry overrides `/login` in the VM: to use another account there, delete
it from the file first. `-SkipClaudeLogin` skips the offer; delete the cached file to forget
the token.

Without it, once per VM:

```bash
ssh dev@<vm-ip> -t claude      # /login -> "Claude account with subscription"
                               # opens a URL; paste the code back into the prompt
```

Token lands in `~/.claude/` and survives reboots — the login is per VM, not per session.

Verify either way: `claude -p "say ok"`

---

## 5. Daily use

**[H]**

```powershell
Start-VM -Name app-foo
mstsc .\app-foo.rdp                       # lossless: 32 bpp, no compression, smart sizing off
ssh dev@<vm-ip> -t tmux attach -t agent
adb connect <vm-ip>:5555                  # the guest emulator, visible to host tooling
adb -s <vm-ip>:5555 exec-out screencap -p > shot.png
Stop-VM -Name app-foo                     # graceful; VMs are cheap, keep them stopped
```

The RDP password is printed once by `New-DevVM.ps1`. It is not secret in any useful sense —
the VMs are only reachable on the local switch — so it is short, and it can be read back or
replaced at any time:

```powershell
.\Get-DevVMPassword.ps1 -Name app-foo                    # from the seed ISO; no elevation needed
.\Get-DevVMPassword.ps1 -Name app-foo | Set-Clipboard
.\Set-DevVMPassword.ps1 -Name app-foo                    # generates one, applies it over ssh, prints it
.\Set-DevVMPassword.ps1 -Name app-foo -Password hunter2
```

`Set-DevVMPassword.ps1` records the new value in `C:\Hyper-V\vms\app-foo\rdp-password.txt`,
which `Get-DevVMPassword.ps1` prefers over the now-stale ISO.

**[G]**

```bash
cd ~/app
npx react-native start &                  # Metro on 8081
npx react-native run-android
claude                                    # agent; logged in once per VM (§4.2)
adb exec-out screencap -p > ~/shots/$(date +%H%M%S).png
adb shell wm density                      # px -> dp for spacing checks
```

---

## 6. Physical devices (§13)

**[P]** on each phone: USB debugging on, *Stay awake* on, adb authorization accepted, adaptive brightness off.

**[H]** one adb server for all guests, at boot:

```powershell
adb kill-server
adb -a -P 5037 nodaemon server
adb devices -l                            # record serials
New-NetFirewallRule -DisplayName "adb from DevVMs" -Direction Inbound -Protocol TCP `
    -LocalPort 5037 -RemoteAddress 192.168.1.0/24 -Action Allow
```

**[G]** — set by cloud-init in `~/.env`, no emulator started:

```bash
export ADB_SERVER_SOCKET=tcp:<host-ip>:5037
export ANDROID_SERIAL=<serial>
adb devices                               # exactly this phone
adb reverse tcp:8081 tcp:8081             # Metro, through the remote server
```

**[H]** visual checks straight over USB: `scrcpy -s <serial> --video-bit-rate 32M --max-fps 60`

---

## 7. Teardown

**[H]**

```powershell
.\Remove-DevVM.ps1 -Name app-foo                  # prompts
.\Remove-DevVM.ps1 -Name app-foo -Force           # scripted
.\Remove-DevVM.ps1 -Name app-foo -KeepFiles       # unregister, keep the disk
```

Runs: `Stop-VM` (graceful, then `-TurnOff` after 60 s) → `Remove-VMSnapshot` if any →
`Remove-VM -Force` → `Remove-Item C:\Hyper-V\vms\app-foo -Recurse` → deletes `app-foo.rdp`.
Refuses if a disk is non-differencing, outside the project folder, or is another VM's parent.

---

## 8. Upgrades

Toolchain (new SDK, Node, system image) — **[H]**, new file, never in place:

```powershell
.\Build-GoldenImage.ps1 -GoldenPath C:\Hyper-V\golden\golden-ubuntu-rn-2026-09.vhdx
.\New-DevVM.ps1 -Name app-foo2 -Repo <url> -GoldenVhdx C:\Hyper-V\golden\golden-ubuntu-rn-2026-09.vhdx
```

The old golden file must stay until its last child is removed.

Config-level changes (MCP server, global `CLAUDE.md`, npm globals) — push to running VMs
instead of rebuilding:

```powershell
ansible -i inventory.ini all -m shell -a 'sudo npm i -g @anthropic-ai/claude-code'
```

---

## 9. Diagnostics

| Symptom | **[G]** check |
|---|---|
| cloud-init did nothing | `sudo cloud-init status --long`; `ls /dev/sr0`; `sudo blkid -L CIDATA` |
| No emulator | `cat /tmp/emu.log`; `ls -l /dev/kvm`; `emulator -accel-check`; `id -nG \| grep kvm` |
| Slow emulator start | snapshot missing: `ls ~/.android/avd/dev.avd/snapshots/golden` |
| Metro unreachable from host | `ss -lntp \| grep 8081`; use `adb reverse`, not the VM IP |
| RDP black screen | `sudo systemctl status xrdp`; `cat ~/.xsession`; light-locker reinstalled? |
| Colour looks off | verify against `adb exec-out screencap -p`, not the RDP window |

| Symptom | **[H]** check |
|---|---|
| No IP after 3 min | `Get-VMNetworkAdapter -VMName app-foo`; switch bound to the right NIC? |
| VM will not start | `Get-VM app-foo \| fl State,Status`; nested virt needs static memory + no checkpoints |
| `adb connect` refused | `systemctl status adb-bridge` in the guest, then `Test-NetConnection <vm-ip> -Port 5555`. The emulator binds 5555 to the guest's loopback only; the socat unit is what publishes it on the LAN. Do **not** "fix" this with `adb tcpip 5555` - see below |
| Guest load average in the hundreds, thousands of `socat` processes | The pre-fix `adb-bridge` bound `0.0.0.0`, which includes loopback - so it forwarded into itself and forked without bound. `sudo systemctl disable --now adb-bridge`, then rebuild the image. Confirm with `pgrep -c socat` (should be 1) and `ss -ltnp \| grep 5555` (should show the LAN address, never `0.0.0.0`) |
| Emulator never appears at boot, cloud-init stuck at `running` | `tail /tmp/emu.log`. A Qt "no platform plugin could be initialized" fatal means the emulator was started windowed with no X display - `~/bin/emu` must add `-no-window` when `DISPLAY` is unset. Until the `timeout` fix, `adb wait-for-device` then blocked runcmd forever, so the `agent` tmux session never started either |
| Windowed emulator fails over RDP but headless works | `libxcb-cursor0` missing. Qt 6.5+ needs it for the xcb plugin; the message names the plugin, not the package |
| `adb exec-out screencap` writes 0 bytes | Something ran `adb tcpip 5555`, which drops the emulator off the guest's own adb server. `adb kill-server && adb start-server` in the guest. Never run `adb tcpip` against the emulator - host access is the adb-bridge unit's job |
