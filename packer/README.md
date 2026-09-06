# Golden image build

Builds `golden-ubuntu-rn.vhdx` — the immutable base every project VM clones from as a
differencing disk. Implements §8.1 of `../linux-vm-on-windows.md`.

For what ends up *inside* the image — every package, service, path and deliberate omission —
see [`../golden-image-contents.md`](../golden-image-contents.md).

```
ubuntu-rn.pkr.hcl              Hyper-V ISO builder + provisioner wiring
Build-GoldenImage.ps1          Wrapper: build -> move -> compact -> mark read-only
http/user-data.pkrtpl.hcl      Ubuntu autoinstall (templated with your SSH public key)
scripts/10-desktop-xrdp.sh     XFCE, xrdp, lossless RDP settings (§6)
scripts/20-node-java.sh        Node LTS, SDKMAN + Temurin 21/17, C/C++ toolchain, watchman
scripts/25-ide-browser.sh      VS Code, xdg-utils, gh, Chrome + Claude extension, Chromium, Playwright
scripts/30-android-sdk.sh      SDK, system image, the "dev" AVD, ~/bin/emu, adb bridge
scripts/40-emulator-snapshot.sh  Boots the AVD once, saves the "golden" snapshot
scripts/50-claude.sh           Claude Code (CLI + VS Code extension), mobile MCP server, global CLAUDE.md
scripts/90-cleanup.sh          Generalization — the step that makes cloning work
```

## Prerequisites

- Hyper-V enabled, with an **external** switch named `DevSwitch` bound to your NIC.
- Packer: `winget install HashiCorp.Packer`, then a **new** shell - winget only
  updates `PATH` for processes started afterwards.
- An SSH keypair at `~/.ssh/id_ed25519` (`ssh-keygen -t ed25519`). The public half is
  templated into the autoinstall config; nothing secret is committed.
- ~70 GB free on the image root (60 GB disk plus the export copy).
- An **elevated** PowerShell session.

### The dev console password

SSH into the image is key-only (`ssh.allow-pw: false`), so the `dev` account's password only
matters at the **Hyper-V console** — `Ctrl+Alt+F2` during a build, or the login prompt on a
VM that failed to come up. The default is:

| user | password |
|---|---|
| `dev` | `devvm` |

Change it by regenerating the hash and overriding the variable:

```powershell
# WSL / Git Bash:
openssl passwd -6
.\Build-GoldenImage.ps1   # then pass -var "dev_password_hash=<hash>", or edit the default in ubuntu-rn.pkr.hcl
```

(The earlier default had no recorded plaintext, which is why a broken build couldn't be logged
into to debug it — hence a known one now.)

## Build

From this directory, in an elevated shell:

```powershell
.\Build-GoldenImage.ps1
```

**The install is unattended, and there is no manual step.** Neither the script nor the Packer
template ever answers an installer prompt. `http/user-data.pkrtpl.hcl` answers all of them in
advance — locale, keyboard, disk layout, hostname, user, SSH key — and Packer burns it onto a
second CD labelled `cidata`, which cloud-init finds by volume label. The only thing typed into
the VM is three lines at the GRUB prompt, which put `autoinstall` on the kernel command line.

So while Packer says `Waiting for SSH to become available`, the VM console should be showing a
scrolling install log. If it is instead showing the installer's own screens — language,
keyboard layout, disk/partitioning, machine name, username — the build has **already failed**
and is now waiting out `ssh_timeout` for a login that will never happen. Don't answer them by
hand; see [below](#the-installer-is-asking-me-questions).

30–50 minutes, most of it the Android system image download and the emulator's first boot.
The result is `C:\Hyper-V\golden\golden-ubuntu-rn.vhdx`, compacted and marked read-only —
which is the default `-GoldenVhdx` in `..\New-DevVM.ps1`.

That root is configurable. `-Root` defaults to `$env:DEVVM_ROOT`, falling back to
`C:\Hyper-V`, and `-GoldenPath` / `-BuildDirectory` derive from it; `New-DevVM.ps1` and
`Remove-DevVM.ps1` resolve theirs the same way. So either set the variable once
(`[Environment]::SetEnvironmentVariable('DEVVM_ROOT', 'E:\Hyper-V', 'Machine')`, then a new
shell) or pass `-Root E:\Hyper-V` to all three scripts — they have to agree.

To run Packer directly instead:

```powershell
packer init .
packer build .
```

…then do the move / `Optimize-VHD` / read-only steps yourself, or re-run
`.\Build-GoldenImage.ps1 -SkipBuild`.

## The two things that most often go wrong

**Nested virtualization on the *build* VM.** `40-emulator-snapshot.sh` boots the emulator
inside the Packer VM, so the builder sets `enable_virtualization_extensions = true` and,
because Hyper-V requires it, `enable_dynamic_memory = false`. Without both, the build runs
for 40 minutes and then fails with no `/dev/kvm`.

**Generalization.** `90-cleanup.sh` runs `cloud-init clean --seed`, truncates
`/etc/machine-id` and deletes the SSH host keys. Skip it and the clones ignore their seed
ISO entirely (no `dev` user, no key, no repo) and fight each other for a single DHCP lease.

## Toolchain versions

**The image tracks latest on purpose.** The Ubuntu point release, the Android API, build-tools,
`cmdline-tools`, adb, the emulator, VS Code, the browsers, Playwright and Claude Code all resolve to the
current version at build time — rebuilding is how the toolchain moves forward, so there is no
reproducible-build goal and two builds from one commit are not the same image.

Two resolutions have guard rails: the Android API is chosen as the newest that has a
`google_apis;x86_64` **system image** (the newest *platform* is regularly ahead of the emulator
images, which yields an AVD that cannot be created), and release candidates are excluded.

Pins are available as overrides when you need one:

```powershell
packer build -var android_api=35 -var android_build_tools=35.0.0 -var node_major=24 .
```

The Ubuntu ISO is resolved by the wrapper rather than the template, so pin it there:

```powershell
.\Build-GoldenImage.ps1 -UbuntuSeries 24.04                      # default: current 24.04.x
.\Build-GoldenImage.ps1 -IsoUrl <url> -IsoChecksum sha256:<hex>  # an exact ISO
```

Full detail, and what to save so you know what a given image contains, in
[`../golden-image-contents.md`](../golden-image-contents.md) §12.

## Upgrading

Never edit the image in place — children read it byte for byte. Build to a new filename:

```powershell
.\Build-GoldenImage.ps1 -GoldenPath C:\Hyper-V\golden\golden-ubuntu-rn-2026-09.vhdx
```

Point new VMs at it and retire the old one when its last child is gone;
`Build-GoldenImage.ps1` refuses to overwrite an image that still has children, and
`Remove-DevVM.ps1` refuses to delete a disk that is somebody's parent.

Small changes — an SDK point release, an updated MCP server, a revised global `CLAUDE.md` —
go through the Ansible path in §8.4 instead. A rebuild is for the toolchain, not for config.

A rebuild is not a reproduction — it is an upgrade, which is the point. Rebuilding an old
commit still gives you current everything. Keep the previous VHDX until its last child is
gone, so there is a known-good image to fall back to if an upstream release breaks something.

## The installer is asking me questions

This is the failure that looks most like a missing feature, so to be explicit: **answering
them is never the intended path.** A VM you clicked through by hand has a random machine-id,
no `dev` SSH key, and none of the generalization `90-cleanup.sh` does — it is not a golden
image, and every clone made from it would be broken.

It means one of three things went wrong, and one command each tells you which. Diagnose
**before** you Ctrl+C — Packer tears the VM down on the way out. Open the VM's console in
Hyper-V Manager, press **`Ctrl+Alt+F2`** for a shell, and:

```bash
cat /proc/cmdline               # must contain the word "autoinstall"
blkid -L cidata                 # must print a device, e.g. /dev/sr1
sudo cloud-init status --long   # must NOT list "Failed loading yaml blob"
```

The third is the one that bites: cloud-init treats the user-data as a single document, so
**one malformed line discards the entire config**. It reports that as a `recoverable_error`
and carries on with nothing, and subiquity — finding no `autoinstall` section — quite
reasonably starts asking questions. Everything upstream looks perfectly healthy while it
happens. `packer validate .` now catches this before anything boots (see below).

If you need more than one round of this, the console gets old fast. Start SSH in the live
environment and work from the host, where you have scrollback and copy/paste:

```bash
sudo systemctl start ssh && sudo passwd ubuntu-server && ip -4 -br a
```

**`autoinstall` is missing from `/proc/cmdline`** — the GRUB boot command didn't land. Either
the menu's countdown expired before Packer started typing, or Hyper-V's synthetic keyboard
dropped a character (a mistyped `autoinstal` is silently ignored by the kernel, which is why
the symptom is identical). Retry with slower typing:

```powershell
.\Build-GoldenImage.ps1 -KeyInterval 250ms
```

That sets `PACKER_KEY_INTERVAL`, the per-keystroke delay. If it still misses, raise
`boot_keygroup_interval` in `ubuntu-rn.pkr.hcl` and add more `<wait2>`s to `boot_command`.

**`blkid -L cidata` finds nothing** — Packer built no seed ISO, so cloud-init had no
datasource and subiquity fell back to asking. That needs an ISO tool: install the Windows ADK
(`winget install Microsoft.WindowsADK`, *Deployment Tools* feature) or pass `-OscdimgPath`.
`Build-GoldenImage.ps1` checks for one before it starts, so this should be rare.

**`cloud-init status --long` says `Failed loading yaml blob`** — the config is invalid YAML and
was discarded whole. The warning names the offending line; fix it in
`http/user-data.pkrtpl.hcl` and confirm with `packer validate .`.

The usual cause is a shell command written as a bare YAML scalar. A command is *not* a scalar:

```yaml
late-commands:
  - echo 'datasource_list: [NoCloud, None]' > /target/etc/...     # BROKEN
  - "echo 'datasource_list: [NoCloud, None]' > /target/etc/..."   # correct
```

The `: ` inside makes YAML read `echo 'datasource_list` as a mapping key and the rest as a
malformed value. **Always double-quote entries in `late-commands` and `early-commands`.**

`ubuntu-rn.pkr.hcl` guards against this with a `local` that runs `yamldecode()` over the
rendered document and reads `.autoinstall.version`. Packer evaluates locals eagerly, so a
malformed document fails `packer validate .` in about a second, rather than 20 minutes into
a build. Run it after touching the autoinstall config:

```powershell
packer validate .
```

## Troubleshooting

| Symptom | Cause |
|---|---|
| Installer shows the language menu, then Packer waits for SSH until it times out | Autoinstall never engaged — the build has failed. See [The installer is asking me questions](#the-installer-is-asking-me-questions). |
| Install completes and reboots, but Packer waits out `ssh_timeout` on a VM that shows a login prompt | Two independent causes, both fixed in the current config. **(a)** `Get-VMNetworkAdapter` reports an empty `IPAddresses`, so the builder never learns the guest IP — the `hv_kvp_daemon` was missing; `linux-cloud-tools-virtual` is now in `packages:`. **(b)** The installed system had no `dev` user and rejected the SSH key — a `datasource_list` pin in the autoinstall `late-commands` redirected first-boot cloud-init to the cidata CD instead of the installer's user/SSH seed. That pin now lives in `90-cleanup.sh` (post-first-boot), where it only affects clones. Check the guest's real IP from the host with `arp -a`, then `ssh dev@<ip>`. |
| Install reaches `postinstall` then dies on `retrieving: unzip` / `curtin ... exit status 100` | apt could not reach the archive: autoinstall's `network:` section replaced the live environment's netplan with one that matches no interface, so the network went down mid-install. Hyper-V's NIC comes over VMBus with no PCI slot for a predictable name, so it stays `eth0` — `match: name: "en*"` alone never hits it. The config matches both `en*` and `eth*`; check with `ip -br link` in the installer shell. |
| Leftover VM is stuck "Shutting Down" and `Stop-VM` fails with `failed to change state` | Hyper-V refuses state changes mid-transition — an ACPI shutdown reached a guest sitting in the installer with nobody to handle it. The script now waits it out and then kills the VM's `vmwp.exe` worker. By hand: `$id = (Get-VM -Name golden-ubuntu-rn).Id.Guid; Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" \| Where-Object { $_.CommandLine -match $id } \| ForEach-Object { Stop-Process -Id $_.ProcessId -Force }` — each VM has its own worker, so this pulls the plug on that one machine only. |
| `A virtual machine with the name golden-ubuntu-rn is already defined in Hyper-V` | An earlier build was interrupted and left its VM behind. Re-run `.\Build-GoldenImage.ps1` — it now asks before deleting it. Say no and it aborts without touching the VM; `-Force` skips the prompt, `-VmName other-name` builds beside it. |
| `packer build` fails to download the ISO, or fails on its checksum | You ran `packer build` directly. The template's `iso_url` default names a specific point release and goes stale — `releases.ubuntu.com/24.04/` keeps only the current one, so the ISO and its `SHA256SUMS` line vanish together. Use `.\Build-GoldenImage.ps1`, which resolves both from one fetch and cannot go stale, or pass `-var iso_url=… -var iso_checksum=sha256:…` yourself. |
| `Could not fetch https://releases.ubuntu.com/<series>/SHA256SUMS` | The wrapper could not reach releases.ubuntu.com, or `-UbuntuSeries` names a series that was never released. Check the series first — a 404 here reads the same as an outage. |
| `No ubuntu-<series>[.x]-live-server-amd64.iso found in …SHA256SUMS` | The sums list downloaded but contained no live-server image — normal for a series that only ships desktop/WSL builds. Pass an explicit `-IsoUrl` / `-IsoChecksum`. |
| watchman download 404s | No longer fatal. Upstream publishes the prebuilt linux zip on only some date-stamped tags, so the build now resolves the newest tag that has one and, failing that, warns and carries on — Metro's own crawler replaces it. Pin a specific tag with `-var watchman_version=…` if you need one. |
| 40-… fails with "KVM is not available" | Nested virtualization is off on the build VM, or disabled in host BIOS (SVM / VT-x). |
| Two clones get the same IP | `/etc/machine-id` was not truncated — the image was booted again after `90-cleanup.sh`. Rebuild, or add `dhcp-identifier: mac` to the guest's netplan. |
| Colours look "close but not exact" over RDP | A lossy codec was negotiated. Check `/etc/xrdp/xrdp.ini` still has compression off, and confirm the value with a PNG via `adb exec-out screencap` (§5). |

## Verifying a fresh image

Before cloning from it, boot one throwaway VM and check:

```bash
emulator -accel-check            # KVM usable
ls -l /dev/kvm                   # exists, group kvm
~/bin/emu -snapshot golden       # emulator on screen in seconds, not 90 s
adb devices                      # emulator-5554  device
systemctl status adb-bridge      # active; then Test-NetConnection <ip> -Port 5555 from the host
claude --version
node --version && java -version
echo "$JAVA_HOME"                # ~/.sdkman/candidates/java/current, not empty
java -version                    # Temurin 21.x
sdk list java | grep installed   # 21 (default) and 17
ssh dev@<ip> java -version       # 21.x too - the /usr/local/bin symlinks, not SDKMAN's hook
cc --version && cmake --version && ninja --version
code --version
code --list-extensions       # anthropic.claude-code
google-chrome --version
playwright --version
ls ~/.cache/ms-playwright    # chromium-*, firefox-*, webkit-*
npx playwright test --browser=chromium --list   # in a project, resolves without downloading
```

The Claude in Chrome extension only downloads when Chrome first starts, so check it from
the desktop rather than over SSH:

```bash
google-chrome &               # over RDP; then chrome://extensions shows "Claude", force-installed
claude --chrome               # /chrome reports Status: Enabled, Extension: Installed
```

And one real build, because it is the only check that exercises the C/C++ toolchain:

```bash
npx --yes @react-native-community/cli@latest init Probe --skip-install
cd Probe && npm install && (cd android && ./gradlew assembleDebug)
```
