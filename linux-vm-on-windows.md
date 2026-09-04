# Parallel React Native Dev Environments on a Windows 11 / Hyper-V Host

A design for running *N* isolated Linux VMs on one Ryzen workstation, each with its own
hardware-accelerated Android emulator and its own Claude Code agent, so several apps can be
developed in parallel while you retain pixel-accurate visual control from the Windows desktop.

---

## 1. Goals and constraints

| Item | Decision |
|---|---|
| Host | Windows 11 (latest build), AMD Ryzen, 64 GB RAM, runs 24/7, owned hardware |
| Hypervisor | Hyper-V (built into Windows 11 Pro) |
| Guest OS | Ubuntu 24.04 LTS with a lightweight desktop (XFCE) |
| Per-VM workload | React Native app + Metro, Android emulator (KVM), Claude Code + Android MCP server |
| Visual access | RDP (xrdp) tuned for lossless colour, plus adb PNG screenshots for exact checks |
| Provisioning | Packer golden image + PowerShell clone script + cloud-init |
| Isolation | One VM per project; separate adb, ports, repo, agent context |

### Why Linux guests (not Windows guests)

- The emulator uses **KVM** directly inside the guest: one thin virtualization layer instead of Hyper-V-inside-Hyper-V plus WHPX.
- Ubuntu + XFCE idles at ~1 GB; a Windows guest needs ~4 GB and a licence just to exist.
- Everything in the agent loop (adb, shell, cloud-init, SSH, Claude Code) is Linux-native and scriptable.
- Cloning a new project VM is a differencing disk + a cloud-init seed, not a Windows install.

---

## 2. Host preparation

1. **Enable Hyper-V and related features** (PowerShell as Administrator, then reboot):
   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
   Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform
   ```
2. **BIOS**: ensure SVM (AMD-V) is enabled. Nested virtualization on AMD requires Windows 11 22H2 or later — the latest build is fine.
3. **Networking**: create an internal or external switch once.
   ```powershell
   New-VMSwitch -Name "DevSwitch" -NetAdapterName "Ethernet"   # external, VMs get LAN IPs
   ```
   An external switch is simplest: each VM gets a DHCP address you can RDP/SSH to directly.
4. **Storage layout** (fast NVMe):
   ```
   C:\Hyper-V\
     golden\golden-ubuntu-rn.vhdx     # immutable base image
     vms\<project>\disk.vhdx          # differencing disk per project
     vms\<project>\seed.iso           # cloud-init NoCloud seed
   ```
   The scripts take this root as `-Root` (default `$env:DEVVM_ROOT`, else `C:\Hyper-V`), so a
   machine with a fast second drive can put the whole tree on it without editing anything.
5. **Tools on the host**: Packer, PowerShell 7, `oscdimg` (from Windows ADK, for building seed ISOs), Android platform-tools (for `adb connect`), optionally Android Studio (Layout Inspector), optionally `scrcpy`.

---

## 3. Capacity plan (64 GB host)

Reserve ~12 GB for Windows itself and headroom. That leaves ~52 GB for guests.

| VM profile | vCPU | RAM | Notes |
|---|---|---|---|
| Standard project VM | 4 | 10 GB | Ubuntu+XFCE ~1.5 GB, emulator 4 GB, Metro/Node/agent ~2 GB, cache |
| Light project VM | 4 | 8 GB | Fine for small apps, smaller AVD (2 GB RAM) |

- **Practical ceiling: 5 standard VMs (50 GB) or 6 light VMs (48 GB) simultaneously.** More projects than that: keep them created but stopped; start/stop as needed.
- Memory must be **fixed (Dynamic Memory off)** — nested virtualization requires it.
- vCPU overcommit of ~1.5–2× is fine; agents spend most time idle waiting on the model. On a 16-core Ryzen, 5 × 4 vCPU = 20 vCPU is comfortable.
- The emulator, not the agent, is the bottleneck. Size around emulator count.

---

## 4. Guest design (what lives in every VM)

| Layer | Contents |
|---|---|
| OS | Ubuntu 24.04 Server + `xubuntu-core` (XFCE), `xrdp`, `openssh-server`, `cloud-init` |
| Runtime | Node LTS (via nvm or NodeSource), OpenJDK 17, watchman |
| Android | cmdline-tools, platform-tools, build-tools, one platform (e.g. API 35), one x86_64 system image (Google APIs), pre-created AVD, `/dev/kvm` access for the `dev` user (`kvm` group) |
| Agent | Claude Code, Android MCP server (e.g. `mobile-mcp`), shared `~/.claude/` config and global `CLAUDE.md` conventions |
| Access | `dev` user with your SSH public key, sudo NOPASSWD, RDP password set by cloud-init |
| Project | Cloned via cloud-init at first boot; `npm install` run; project-specific env in `~/.env` |

### Emulator configuration

- Run **windowed on the XFCE desktop** so you can see it over RDP, but it works identically headless.
- Launch flags (in a `~/bin/emu` wrapper):
  ```bash
  emulator -avd dev -gpu swiftshader_indirect -no-boot-anim -no-audio \
           -no-snapshot-save -port 5554 "$@"
  ```
  Software GPU is required (no GPU passthrough in Hyper-V Linux guests); it's plenty for RN UI work.
- **Pre-boot the AVD in the golden image and save a snapshot** (`-snapshot golden`) so a fresh VM starts the emulator in seconds rather than 60–90 s.
- Verify acceleration after first boot: `emulator -accel-check` should report KVM is usable and `ls -l /dev/kvm` should exist.
- Set the emulator window zoom to **1:1** (one device pixel = one screen pixel) so margins aren't antialiased away during visual checks.

### Ports and identity per VM

Each VM is its own machine, so ports don't clash — but for tooling clarity keep conventions:

| Purpose | Port |
|---|---|
| SSH | 22 |
| RDP (xrdp) | 3389 |
| adb (tcp) | 5555 (published by `adb-bridge.service`) |
| Emulator console / adb | 5554 / 5555 (guest loopback only) |
| Metro | 8081 |

From the host, `adb connect <vm-ip>:5555` makes any VM's emulator visible to Android Studio or scrcpy.

This works only because of `adb-bridge.service`, a socat unit baked into the image. The
emulator binds its adb port to the guest's **loopback** interface and offers no flag to
change that, so without the bridge the host's `adb connect` is refused - there is nothing
listening on an address the host can reach. The tempting fix, `adb tcpip 5555`, does not
work: it moves the guest Android's adbd to TCP mode behind qemu's NAT, still unreachable
from the host, and additionally knocks the emulator off the guest's own adb server, after
which a local `adb exec-out screencap` silently produces a zero-byte file.

---

## 5. Visual verification (colours, fonts, spacing)

Ranked by fidelity, most exact first:

1. **PNG screenshots via adb — ground truth.**
   `adb exec-out screencap -p > screen.png` is a lossless framebuffer capture. View at 100 % zoom on Windows, use an eyedropper for exact hex values, measure in pixels and divide by density (`adb shell wm density`; e.g. 2.625× → 24 dp = 63 px). Have Claude drop screenshots into `~/shots/` after each change; sync that folder to the host for review.
2. **RDP into the VM (xrdp), tuned lossless — daily driver.** See §6.
3. **React Native Element Inspector** (dev menu → *Show Element Inspector*, or React DevTools): tap any element to read its computed margin, padding, fontSize, colour. Answers "is it 16 or 12 dp?" without measuring.
4. **Android Studio Layout Inspector on the host** via `adb connect`: exact bounds and 3D view for native components.
5. **scrcpy** (`scrcpy --video-bit-rate 32M --max-fps 60`): optional, leaner than RDP, near-lossless at high bitrate.

Avoid the Hyper-V "Basic Session" console for visual checks: it scales and software-renders, so colours and 1 dp edges are unreliable.

---

## 6. xrdp lossless configuration

In the guest `/etc/xrdp/xrdp.ini`:

```ini
[Globals]
max_bpp=32
bitmap_compression=false
bulk_compression=false
; keep only the lossless path; remove rfx/jpeg entries from the codec list if present
```

Restart with `sudo systemctl restart xrdp`.

On the Windows side (`mstsc`):

- Display: full screen or a fixed size matching your monitor; **"Smart sizing" off**, DPI scaling 100 %.
- Experience: **"LAN (10 Mbps or higher)"**, 32-bit colour.
- Save one `.rdp` file per VM (`app-foo.rdp`) with the VM's IP — the clone script can emit these.

With these settings, each guest pixel maps to one host pixel and colours are transmitted as sent. Still confirm any disputed hex value with a PNG (method 1 in §5).

---

## 7. Claude Code in each VM

- Installed globally in the golden image, with no credentials in it. Authentication is a one-off interactive `/login` against your Claude subscription in each new VM; the token lands in the guest's `~/.claude/` and survives reboots. (An API key injected per VM by cloud-init is the alternative — fewer manual steps, but a long-lived secret sitting in every guest.)
- **Android MCP server** configured in `~/.claude/` so the agent has tools such as `take_screenshot`, `list_elements_on_screen`, `tap_element`, `type_text`, `swipe`. This is far more reliable than raw `adb shell input tap x y`.
- A global `CLAUDE.md` in the image covers shared conventions: how to start the emulator, how to reload Metro, where to save screenshots, the verification loop (build → reload → screenshot → inspect → act).
- Each project's repo adds its own `CLAUDE.md` for app-specific context.
- Run the agent in a `tmux` session started by cloud-init so it survives RDP/SSH disconnects; attach with `ssh dev@<vm-ip> -t tmux attach`.

---

## 8. Automated provisioning

### 8.1 Golden image with Packer (build once, rebuild on SDK/Node upgrades)

```
packer/
  ubuntu-rn.pkr.hcl        # Hyper-V ISO builder
  http/user-data           # Ubuntu autoinstall config (disk, user, ssh)
  scripts/
    10-desktop-xrdp.sh     # XFCE, xrdp, lossless settings
    20-node-java.sh        # Node LTS, JDK 17, watchman
    30-android-sdk.sh      # cmdline-tools, platform-tools, system image, AVD
    40-emulator-snapshot.sh# boot AVD once, save "golden" snapshot
    50-claude.sh           # Claude Code, MCP server, global CLAUDE.md
    90-cleanup.sh          # cloud-init clean, remove machine-id, ssh host keys, apt clean
```

Key `packer` builder settings:

```hcl
source "hyperv-iso" "ubuntu" {
  iso_url            = "https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso"
  generation         = 2
  enable_secure_boot = false
  cpus               = 4
  memory             = 8192
  disk_size          = 61440
  switch_name        = "DevSwitch"
  cd_label           = "cidata"            # autoinstall seed as a CD, not over HTTP
  cd_content         = { "user-data" = templatefile(...), "meta-data" = "..." }
  boot_keygroup_interval = "250ms"         # Hyper-V's keyboard drops fast keystrokes
  boot_command       = ["<esc><wait>c<wait>linux /casper/vmlinuz autoinstall ---<enter><wait>initrd /casper/initrd<enter><wait>boot<enter>"]
  ssh_username       = "dev"
  ssh_private_key_file = "~/.ssh/id_ed25519"
  output_directory   = "C:/Hyper-V/golden"
  vm_name            = "golden-ubuntu-rn"
}
```

Output: `C:\Hyper-V\golden\golden-ubuntu-rn.vhdx`. Treat it as immutable.

### 8.2 Per-project clone: `New-DevVM.ps1`

Usage:

```powershell
.\New-DevVM.ps1 -Name app-foo -Repo git@github.com:you/foo.git -Memory 10GB -Cpus 4
```

What it does:

1. **Differencing disk** (thin clone, seconds):
   ```powershell
   New-VHD -Path "C:\Hyper-V\vms\$Name\disk.vhdx" `
           -ParentPath "C:\Hyper-V\golden\golden-ubuntu-rn.vhdx" -Differencing
   ```
2. **Create the VM** with nested virtualization:
   ```powershell
   New-VM -Name $Name -Generation 2 -MemoryStartupBytes $Memory `
          -VHDPath "C:\Hyper-V\vms\$Name\disk.vhdx" -SwitchName DevSwitch
   Set-VM -Name $Name -StaticMemory -AutomaticStartAction Nothing
   Set-VMProcessor -VMName $Name -Count $Cpus -ExposeVirtualizationExtensions $true
   Set-VMNetworkAdapter -VMName $Name -MacAddressSpoofing On
   Set-VMFirmware -VMName $Name -EnableSecureBoot Off
   Set-VM -Name $Name -CheckpointType Disabled
   ```
3. **cloud-init NoCloud seed** — render `user-data`/`meta-data` from a template, build `seed.iso` with `oscdimg`, attach as DVD:
   ```powershell
   Add-VMDvdDrive -VMName $Name -Path "C:\Hyper-V\vms\$Name\seed.iso"
   ```
4. **Start**, wait for an IP, print connection lines and write `app-foo.rdp`:
   ```powershell
   Start-VM -Name $Name
   # poll Get-VMNetworkAdapter -VMName $Name | select -expand IPAddresses
   ```

Companion `Remove-DevVM.ps1 -Name app-foo` stops the VM, removes it, and deletes the project folder.

### 8.3 cloud-init `user-data` template

```yaml
#cloud-config
hostname: ${NAME}
users:
  - name: dev
    groups: [sudo, kvm]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ${SSH_PUBKEY}
chpasswd:
  list: |
    dev:${RDP_PASSWORD}
  expire: false
write_files:
  - path: /home/dev/.env
    owner: dev:dev
    permissions: '0600'
    content: |
      # No Anthropic credentials: the agent logs in per VM against your subscription (§7).
      PROJECT=${NAME}
      # Physical device mode (see §12). Leave DEVICE_SERIAL empty to use the emulator.
      ADB_SERVER_SOCKET=tcp:${HOST_IP}:5037
      ANDROID_SERIAL=${DEVICE_SERIAL}
runcmd:
  - sudo -u dev git clone ${REPO} /home/dev/app
  - sudo -u dev bash -lc 'cd ~/app && npm install'
  # Emulator only when no phone is assigned to this VM
  - sudo -u dev bash -lc '[ -z "${DEVICE_SERIAL}" ] && (unset ADB_SERVER_SOCKET; ~/bin/emu -snapshot golden >/tmp/emu.log 2>&1 &) || true'
  - sudo -u dev bash -lc '[ -z "${DEVICE_SERIAL}" ] && (unset ADB_SERVER_SOCKET; sleep 20 && adb wait-for-device) || true'
  - sudo -u dev tmux new -d -s agent -c /home/dev/app
```

`New-DevVM.ps1` takes an optional `-DeviceSerial` parameter; when set, the VM is created with less RAM (6 GB) and the emulator is skipped.

### 8.4 Keeping running VMs in sync (optional)

Keep an Ansible inventory of live VMs (`app-foo ansible_host=192.168.1.51`, …). One playbook can push a new SDK version, an updated MCP server, or a revised global `CLAUDE.md` to all of them without a rebuild. For anything larger, rebuild the golden image and recreate VMs — they are cheap.

---

## 9. Daily workflow

1. `.\New-DevVM.ps1 -Name app-bar -Repo …` — VM up in ~2 minutes, emulator already running from snapshot.
2. `ssh dev@<ip> -t tmux attach` → start Claude Code on the task.
3. Claude builds, reloads Metro, screenshots, inspects, taps — via the MCP server — and saves PNGs to `~/shots/`.
4. When you want to check: double-click `app-bar.rdp`, look at the emulator window at 1:1, use the RN inspector for numbers; open a PNG at 100 % and eyedropper anything where the exact hex matters.
5. Stop VMs you're not using (`Stop-VM app-bar`) to keep within the 5–6 concurrent budget; they resume in seconds with their differencing disk intact.

---

## 10. Known caveats

- **Nested virtualization on AMD under Hyper-V** is supported but has historically been less polished than on Intel. Expect emulator cold boot to be slower than native; snapshots make this a non-issue after the first boot. Validate with one VM before cloning five.
- **No GPU acceleration** in the guests; the emulator uses SwiftShader. Fine for RN UI, slow for heavy 3D/games — use physical devices for those (§12–13).
- **Dynamic Memory and checkpoints** must be off on nested-virt VMs; plan RAM statically.
- **One hypervisor per host**: Hyper-V and VirtualBox/VMware won't coexist at full speed.
- **Secrets**: nothing credential-shaped goes into the golden image. The agent logs in per VM against the subscription; anything else a project needs is injected by cloud-init into `~/.env`.
- **Differencing disks** depend on the parent — never modify or delete the golden `.vhdx` while children exist; build a new golden file for upgrades and migrate.

---

## 11. Alternative considered: Linux host

If the host OS ever becomes negotiable, a Linux host (Proxmox or Ubuntu + KVM) is the stronger platform for this workload: no nesting at all (emulators run in Docker containers sharing the host's `/dev/kvm`, one per project), roughly 2× emulator density for the same hardware, and mature KVM-on-AMD. Windows would then live as a guest with GPU passthrough. The provisioning approach (golden image + clone + cloud-init) carries over unchanged.

---

## 12. GPU-intensive apps and games

SwiftShader is software rendering. It is adequate for forms, lists and navigation, but a 3D or particle-heavy game will run at single-digit fps in the emulator, and you cannot judge feel, jank or shader output from that. Games need a real GPU in the render path, and Hyper-V on Windows 11 offers Linux guests no clean way to get one (GPU partitioning targets Windows guests; DDA passthrough is Windows Server only).

Options, best fit first:

| Option | Fit | Notes |
|---|---|---|
| **Physical phones per project** (§13) | Best | Real GPU, thermals, touch latency. Works with the existing VM design unchanged. Chosen approach. |
| Linux host, emulators in Docker sharing one discrete GPU | Very good | Only path to *virtualised* environments with proper GPU rendering at density. Requires replacing Windows as host (§11). |
| WSL2 with `dxgkrnl` + Mesa D3D12, emulator `-gpu host` | Experimental | One shared kernel, projects as distros not VMs; Mesa-on-D3D12 is slower and less proven. Worth a one-hour test only. |
| Windows guests with GPU-P (Easy-GPU-PV) + nested Hyper-V | Poor | Two layers of Windows plus GPU partitioning; fragile and heavy. Avoid. |

Decision: keep the VM/emulator design for UI-first apps; assign a physical phone to any game or GPU-heavy project. If the game portfolio grows, that is the point to revisit a Linux host rather than fighting Hyper-V for GPU access.

---

## 13. Physical devices over USB

The phones replace the emulator as the render target. The VM still builds the app, runs Metro and hosts the agent; it just talks to a real device over adb instead of an AVD. Hyper-V does not pass USB through to Linux guests, so the phones stay attached to the **host** and adb bridges the gap.

### 13.1 Topology (recommended): one adb server on the host, VMs as remote clients

```
[phones] --USB--> [Windows host: adb server, port 5037] <--TCP-- [VM 1] [VM 2] … [VM n]
                              |
                          scrcpy -s <serial> (your visual checks, 60 fps over USB)
```

**Host setup**

1. Powered USB hub; all phones plugged in, USB debugging enabled, RSA authorization accepted once each.
2. Run a single adb server bound to all interfaces, as a scheduled task or service that starts at boot:
   ```powershell
   adb kill-server
   adb -a -P 5037 nodaemon server
   ```
3. Windows Firewall: allow inbound TCP 5037 on the profile used by `DevSwitch` (restrict to the VM subnet).
4. Record each phone's serial (`adb devices -l`) and its role in a small table (`devices.md`): serial, model, Android version, GPU tier, assigned project.

**Guest setup** (injected by cloud-init, see §8.3)

```bash
export ADB_SERVER_SOCKET=tcp:<host-ip>:5037   # use the host's adb server
export ANDROID_SERIAL=<serial>                  # pin this VM to exactly one phone
```

With both set, `adb devices`, `adb exec-out screencap -p`, `adb shell input tap`, `npx react-native run-android`, Metro reload and the Android MCP server all operate on that phone only. The serial pin guarantees project A never touches project B's device. The guest runs only the adb *client* — no USB, no USB/IP, no kernel modules. If Metro's reverse port is needed: `adb reverse tcp:8081 tcp:8081` (works through the remote server).

### 13.2 Alternatives

- **Wi-Fi adb**: `adb tcpip 5555` on the phone, `adb connect <phone-ip>:5555` from the VM. No host adb server needed, but Wi-Fi debugging drops and screenshots/scrcpy are slower than USB.
- **USB/IP (`usbipd-win`)**: attaches the raw USB device to a guest. Only worth it for something adb cannot do (flashing, MTP). Adds a kernel module and per-VM attach step.

### 13.3 What changes in the design

- **Capacity**: a phone-backed VM needs no emulator → 4 vCPU / 6 GB. On 64 GB that is ~8 concurrent projects instead of 5.
- **Visual checks**: run `scrcpy -s <serial>` on the host directly over USB — better frame rate and colour than RDP into the VM. PNG-eyedropper checks are unchanged (`adb -s <serial> exec-out screencap -p` from host or guest). The RN Element Inspector and Android Studio Layout Inspector work on real devices exactly as on the emulator.
- **Agent loop**: identical. The MCP server sees the phone as its device; screenshot → inspect → tap → screenshot.
- **Golden image**: keep the emulator installed. A VM created without `-DeviceSerial` falls back to the AVD.

### 13.4 Device hygiene

- Developer options: *Stay awake* (while charging) on; screen lock off or set to None; *Disable adb authorization timeout* on.
- Set a fixed, low brightness and disable adaptive brightness so colour checks are stable.
- Disable auto-updates and notifications on test phones to avoid interruptions during agent runs.
- Powered hub with enough current for all devices; label phones physically with their serial's last four characters.
- Mixed device tiers are a feature: pair each game with a realistic low-end target, not only the fastest phone.