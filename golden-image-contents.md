# What ships with the golden image

Contents of `golden-ubuntu-rn.vhdx` — the image `New-AgentVM.ps1` clones with a differencing
disk. This describes the **artifact**; `packer/README.md` describes how to build it and
`runbook.md` describes how to drive a VM once it exists.

Everything here is derived from `packer/ubuntu-rn.pkr.hcl` and the seven provisioner scripts
under `packer/scripts/`. Those files are the source of truth — if this document and a script
disagree, the script wins.

---

## 1. Base system

| | |
|---|---|
| OS | Ubuntu 24.04 LTS server — the **current** point release, resolved at build time (§12) |
| Install | subiquity autoinstall via cloud-init NoCloud, seed on a CD labelled `cidata` |
| Disk layout | `direct` — whole disk, **no LVM** (LVM caps the root LV and strands most of the disk) |
| Virtual disk | 60 GB dynamic VHDX, Gen 2, Secure Boot off |
| User | `dev`, passwordless sudo via `/etc/sudoers.d/90-dev` |
| SSH | key-only (`allow-pw: false`); the build key is `~/.ssh/id_ed25519.pub` from the host |
| Console password | `devvm` by default — only reachable at the Hyper-V console, never over SSH |
| Networking | DHCP, matching both `en*` and `eth*` (Hyper-V's VMBus NIC stays `eth0`) |

Base packages from the autoinstall: `openssh-server`, `curl`, `ca-certificates`, `unzip`,
`python3`, `linux-cloud-tools-virtual`.

`linux-cloud-tools-virtual` is not optional — it provides `hv_kvp_daemon`, which is how the
guest reports its IP back to Hyper-V. Without it `Get-VMNetworkAdapter` shows no address and
both Packer and `New-AgentVM.ps1` wait out their timeouts on a VM that was reachable the whole
time.

## 2. Desktop and remote access

`10-desktop-xrdp.sh`

- **XFCE** via the `xfce4` metapackage — session, `xfwm4`, panel, `xfdesktop4`, settings,
  Thunar. Not the full Xubuntu application set, and no display manager: the session is
  launched straight from `~/.xsession`.
- **xrdp** on 3389, enabled at boot, configured for **lossless** output:

  | Setting | Value | Why |
  |---|---|---|
  | `max_bpp` | 32 | colours must arrive as sent |
  | `bitmap_compression` | false | |
  | `bulk_compression` | false | |
  | `rfx_compression` | false — *only rewritten where the shipped `xrdp.ini` has the key; xrdp 0.10 on 24.04 does not, so there is no codec line to disable* | a client must not negotiate a lossy codec behind your back |
  | `jpeg_compression` | as above | |
  | `new_cursors` | true | |
  | `use_fastpath` | both | |

  The point of the desktop is *visual verification* — an eyedropper reading off a compressed
  frame is meaningless.

- `light-locker` purged and `xfce4-screensaver` masked with a `Hidden=true` autostart entry.
  A lock screen over xrdp is the classic black-screen-on-reconnect bug and is pointless on a
  disposable VM.
- A polkit rule (`/etc/polkit-1/rules.d/45-allow-colord.rules`) that auto-approves colour
  manager actions, so an xrdp session does not sit behind an authentication prompt nobody is
  at the console to dismiss.
- Shell tools: `tmux`, `git`, `jq`, `unzip`, `zip`, `file`, `htop`, `net-tools`, `iproute2`,
  `xfce4-terminal`, `dbus-x11`.

## 3. Language runtimes and build toolchain

`20-node-java.sh`

| Component | Version | Source |
|---|---|---|
| Node.js | 22.x LTS (`node_major`) | NodeSource apt repo |
| npm | bundled with Node | |
| SDKMAN | current | `get.sdkman.io`, installed into `~/.sdkman` for the `dev` user |
| Temurin JDK | newest 21.x (default) and newest 17.x | SDKMAN (`sdk install java`) |
| watchman | newest release with a Linux zip | GitHub releases — **optional** |
| C/C++ toolchain | `build-essential`, `cmake`, `ninja-build`, `pkg-config`, `python3-dev` | Ubuntu archive |

The JDKs come from SDKMAN rather than the archive's `openjdk-*-jdk` packages, so a VM can
add or switch majors itself — `sdk install java 25-tem`, no image rebuild and no root.
`JDK_MAJORS` (default `21 17`) and `JDK_VENDOR` (default `tem`) control what the build
installs; the first major listed becomes the SDKMAN default. Neither is pinned to a patch
version: the build resolves the newest identifier per major out of `sdk list java`.

21 leads because `@capacitor/android` compiles its own sources at Java 21 from Capacitor 7
on. 17 is there for projects whose Gradle predates 8.5 and so cannot run on a 21 JDK at all;
they select it with `sdk use java 17...` or by overriding `JAVA_HOME`.

SDKMAN is a shell function in `~/.sdkman`, hooked into `~/.bashrc`, which covers interactive
and login shells and nothing else — not systemd units, and not `ssh vm '<command>'`. Two
things bridge that gap, both pointing at SDKMAN's `candidates/java/current` symlink so
`sdk default java` stays the one place the version is decided:

- `/etc/profile.d/java.sh` exports `SDKMAN_DIR`, `JAVA_HOME` and `PATH`;
- `java`, `javac`, `jar`, `jarsigner` and `keytool` are symlinked into `/usr/local/bin`,
  which is on the default non-interactive `PATH`.

Both resolve through `/home/dev/.sdkman`, so the JDK is readable by `dev` and by root, and
not by any other unprivileged user the guest might grow.

The C/C++ toolchain is required even though nothing in a React Native `package.json` names
it. `node-gyp` compiles the native halves of ordinary npm dependencies, and React Native's
own Android build runs CMake + Ninja to build Hermes and the JSI native modules. Omit it and
`npm install` and the first `./gradlew assembleDebug` fail on a missing compiler, deep inside
build output that does not obviously say so.

watchman is best-effort by design. Its prebuilt Linux zip is published on only *some* release
tags, and a pinned tag that later loses its asset used to kill the build 18 minutes in. It is
a file-watching daemon Metro uses if present and otherwise replaces with its own crawler —
slower on a large tree, identical in behaviour. A failure here warns and continues.

## 4. IDE and browser

`25-ide-browser.sh`

- **Visual Studio Code**, from the Microsoft apt repository, keyed through
  `/usr/share/keyrings/microsoft.gpg` with `signed-by` (not the deprecated `apt-key`).
- **`xdg-utils`** — what "Open Folder", clicking a link in the terminal, and VS Code's
  "open in browser" all shell out to. Missing, those silently do nothing.
- **GitHub CLI (`gh`)**, from the GitHub apt repository, keyed through
  `/etc/apt/keyrings/githubcli-archive-keyring.gpg` with `signed-by`. The binary only: it
  is logged into nothing, and section 10 covers what stays out.
- **Google Chrome**, from Google's apt repository — the host for the Claude extension below.
- **Claude in Chrome extension** (`fcoeoabgfenejglbffodgkkbkcdhcgfn`), force-installed
  through an `ExtensionInstallForcelist` entry in
  `/etc/opt/chrome/policies/managed/claude-in-chrome.json`. Chrome fetches the extension
  itself on first launch; the build only writes and JSON-checks the policy.
- **Chromium**, `apt` first with a `snap install chromium` fallback. Convenience for web
  work rather than a build dependency, so a failure warns and the image is still good.
- **Playwright** (`@playwright/test`, global) with the Chromium, Firefox and WebKit builds
  in `~/.cache/ms-playwright` and their shared libraries via `playwright install-deps`.
  Unlike Chromium, this one is fatal on failure. `PLAYWRIGHT_VERSION` and
  `PLAYWRIGHT_BROWSERS` control it.

Bare XFCE ships with neither an editor nor a browser, which is the reason this script
exists; `gh` rides along because every project VM ends up wanting it.

Chrome is present *as well as* Chromium because of how Claude Code reaches the extension:
through a native messaging host — a manifest in the browser's config directory naming a
binary the browser launches. The Chromium snap satisfies neither half, keeping its config
under `~/snap/chromium` and refusing to launch a binary from `/usr/local`, and the
integration supports Chrome, Edge and the unconfined Chromium forks rather than Chromium
itself. Claude Code writes that manifest itself on the first `claude --chrome`, so nothing
about it is baked into the image.

Playwright's browsers sit in the `dev` user's cache, where Playwright looks by default —
no `PLAYWRIGHT_BROWSERS_PATH` to export, and so nothing to go missing in the profile-less
shells that run tests over `ssh`. A project depending on a different `@playwright/test`
than the global one downloads its own matching build into that same cache on first run: a
slower first test, not a failure, and the reason nothing here is pinned.

## 5. Android SDK and emulator

`30-android-sdk.sh`, `40-emulator-snapshot.sh`

**SDK** at `~/Android/Sdk`:

| Package | Version |
|---|---|
| `cmdline-tools;latest` | current — the pinned zip is only the build's own `sdkmanager`, and installs this at the end. Since 23.0 the `sdkmanager` here is a shim over a new `android` CLI that downloads itself on first run; `avdmanager` is still the classic tool |
| `platform-tools` (`adb`) | current |
| `emulator` | current |
| `platforms;android-<API>` | newest bootable API (`android_api` to pin) |
| `build-tools;<ver>` | newest stable on the resolved API's line, RCs skipped (`android_build_tools` to pin) |
| `system-images;android-<API>;google_apis;x86_64` | ~1.5 GB |

`<API>` is resolved at build time as the newest API level that actually has a
`google_apis;x86_64` system image — not simply the newest platform, which is regularly ahead
of the emulator images and would produce an AVD that cannot be created. See §12.

All SDK licences are pre-accepted.

**Emulator runtime deps:** `qemu-kvm`, `libvirt-daemon-system`, `libpulse0`, `libnss3`,
`libxcomposite1`, `libxcursor1`, `libxi6`, `libxtst6`, `libasound2t64`, `libgl1`, `libc++1`,
`libxcb-cursor0`, `socat`, `android-sdk-platform-tools-common`. `dev` is added to the `kvm`
group.

`libxcb-cursor0` is the easy one to miss: Qt 6.5+ needs it to load the xcb platform plugin,
and without it a *windowed* emulator dies on "no Qt platform plugin could be initialized" —
a message that names the plugin, never the package. Headless runs are unaffected, so this
only matters over RDP.

**The `dev` AVD** — Pixel 6, the resolved API + Google APIs, x86_64:

| Key | Value |
|---|---|
| `hw.ramSize` | 4096 (`avd_ram_mb`) |
| `vm.heapSize` | 512 |
| `disk.dataPartition.size` | 6G |
| `hw.gpu.mode` | `swiftshader_indirect` |
| `hw.keyboard` | yes |
| `hw.audioInput` / `hw.audioOutput` | no |
| `showDeviceFrame` | no |

There is no GPU passthrough into Hyper-V Linux guests, so the software rasterizer is the only
option — and it renders React Native UI accurately, which is what this image is for.

**The `golden` snapshot** is the reason the image is worth building. `40-emulator-snapshot.sh`
cold-boots the AVD once, waits for `sys.boot_completed`, then waits up to 5 minutes for
`init.svc.bootanim` to stop — treating the property being unset as "the image never started
bootanim, so there is nothing to wait for" — and sleeps a further 30 s so the snapshot is not
taken mid-storm of package optimisation and GMS setup. It zeroes the three animation scales, saves the snapshot, and verifies it hit
the disk.

A cloned VM resumes it in **~15 seconds**, against 60–90 s for a cold boot. Start it with
`~/bin/emu -snapshot golden`.

**`~/bin/emu`** wraps `emulator -avd dev -gpu swiftshader_indirect -no-boot-anim -no-audio
-no-snapshot-save -port 5554 "$@"`, and adds `-no-window` when `DISPLAY` is unset:

```bash
args=()
if [ -z "${DISPLAY:-}" ]; then
    args+=(-no-window)
fi
```

The emulator is windowed by default, and there is no X display for anything started from
cloud-init, systemd or a plain SSH session — the xrdp X session exists only while someone is
connected. Windowed with no display it dies immediately on a Qt "no platform plugin could be
initialized" fatal, and whatever launched it waits on an emulator that will never register.
Deciding from `DISPLAY` means callers do not have to remember: over RDP you get a window,
everywhere else it runs headless and adb works the same.

**`adb-bridge.service`** (systemd, enabled, runs as `dev`) republishes the emulator's adb port
on the LAN interface, via `/usr/local/bin/adb-bridge`:

```bash
lan_ip="$(ip -4 -o route get 1.1.1.1 | awk '{print $7; exit}')"
exec socat "TCP-LISTEN:5555,fork,reuseaddr,bind=${lan_ip}" TCP:127.0.0.1:5555
```

It binds **one address**, never `0.0.0.0`. Binding all interfaces includes loopback, which
makes socat's listener answer socat's own forward target — with `fork`, every connection
spawns a child that connects back into the listener, without bound — and it simultaneously
takes `127.0.0.1:5555` away from the emulator, which needs exactly that address. The LAN
address comes from DHCP, so it is resolved at service start; if the lease ever changes it,
the bridge needs `sudo systemctl restart adb-bridge`, since nothing has crashed for
`Restart=always` to catch.

The emulator binds 5555 to the guest's **loopback only** and no emulator flag changes that, so
`adb connect <vm-ip>:5555` from the Windows host — the entire point of that port — is refused.
`adb tcpip 5555` is *not* the fix despite looking like it: it switches the guest Android's
`adbd` to TCP mode behind qemu's NAT, which the host still cannot route to, **and** it drops
the emulator off the VM's own adb server, after which a local `adb exec-out screencap`
silently writes a zero-byte file until someone restarts the server. The bridge survives
emulator restarts; with nothing running it simply has nothing to forward.

## 6. Agent tooling

`50-claude.sh`

- **Claude Code**, `npm install -g @anthropic-ai/claude-code`.
- **Claude Code extension for VS Code**, `code --install-extension anthropic.claude-code`,
  installed as `dev` because extensions are per-user (`~/.vscode/extensions/`). It ships its
  own Claude Code binary and needs the same one-off per-VM login as the CLI.
- **`mobile` MCP server** registered at user scope: `npx -y @mobilenext/mobile-mcp@latest`.
  Driving the UI through `tap_element` / `list_elements_on_screen` is far more reliable than
  `adb shell input tap x y` against coordinates the agent guessed.
- **`~/.claude/CLAUDE.md`** — machine conventions: where the repo lives (`~/app`), how to
  start the emulator warm, the screenshot verification loop, and the rule that long-running
  processes belong in `tmux`.
- **`~/shots/`**, created empty, for screenshots.

**No credentials ship in the image.** It is shared by every project VM, so it must be
login-free. Each VM is logged in after boot, over SSH: `New-AgentVM.ps1` writes a
`claude setup-token` subscription token into that guest's `~/.claude/settings.json` when
asked to, or you run a one-off interactive `/login` there. Either way the token stays in
that one guest's `~/.claude`.

## 7. System-wide environment

Three files in `/etc/profile.d/`, so login shells and cloud-init both see them:

| File | Exports |
|---|---|
| `android.sh` | `ANDROID_HOME`, `ANDROID_SDK_ROOT`, and `PATH` += `cmdline-tools/latest/bin`, `platform-tools`, `emulator`, `~/bin` |
| `java.sh` | `SDKMAN_DIR=/home/dev/.sdkman`, `JAVA_HOME=$SDKMAN_DIR/candidates/java/current`, and `PATH` += `$JAVA_HOME/bin` |

`JAVA_HOME` is set explicitly because Gradle will find a JDK on `PATH` but the React Native and
Capacitor CLIs read the variable directly and print "JAVA_HOME is not set" rather than falling
back. Shells that read no profile at all are covered by the `/usr/local/bin` symlinks in
section 3.

## 8. Services enabled at boot

| Service | Port | Purpose |
|---|---|---|
| `ssh` | 22 | key-only |
| `xrdp` | 3389 | XFCE desktop |
| `adb-bridge` | 5555 **on the LAN address only** | publishes the emulator's loopback adb port; loopback:5555 stays free for the emulator itself |

Not enabled: the emulator itself and Metro. `New-AgentVM.ps1` starts those per VM through
cloud-init `runcmd`, in a `tmux` session.

## 9. Home directory layout

```
~/Android/Sdk/                       SDK root
~/.android/avd/dev.avd/              the AVD
~/.android/avd/dev.avd/snapshots/golden/    the pre-booted snapshot
~/bin/emu                            emulator wrapper
~/shots/                             screenshots
~/.claude/CLAUDE.md                  machine conventions
~/.claude.json                       MCP server registration
~/.vscode/extensions/                Claude Code extension for VS Code
~/.xsession                          "xfce4-session"
```

## 10. What is deliberately *not* in the image

`90-cleanup.sh` generalizes the disk. This is the step that decides whether cloning works at
all — anything machine-specific left behind is duplicated into every child VM.

| Removed / reset | Why |
|---|---|
| `/etc/machine-id` **truncated, not deleted** | systemd regenerates a unique id into an existing empty file; two VMs sharing one share a DHCP DUID and fight over a lease |
| `/var/lib/dbus/machine-id` → symlink | follows the above |
| `/etc/ssh/ssh_host_*` | cloud-init regenerates them; otherwise every VM has one identity and clients raise host-key warnings |
| cloud-init state (`cloud-init clean --logs --seed`, `/var/lib/cloud/instance*`) | without this cloud-init believes it has already run and ignores the per-VM seed ISO — no `dev` user, no SSH key, no `~/app` |
| apt lists and caches | size |
| all of `/var/log`, journal, `/var/tmp`, bash history | size and hygiene |
| AVD lock files and `snapshots/default_boot` | live QEMU state would resume into a stale session; `snapshots/golden` is what we keep |
| `~/.android/cache`, `adbkey`, `adbkey.pub` | per-machine adb identity |

Also added by cleanup: `/etc/cloud/cloud.cfg.d/99-nocloud.cfg` pinning
`datasource_list: [NoCloud, None]`, so clones probe only the seed `New-AgentVM.ps1` attaches
instead of walking every datasource cloud-init knows. This is done here rather than in the
autoinstall on purpose — pinning it earlier redirects the installer's own first-boot run to
the autoinstall CD, which creates no user, and the image ends up with no `dev` account at all.

Finally `fstrim -av` zeroes free space so `Optimize-VHD` can compact the VHDX.

Not present for other reasons: **no project repository**, **no warm npm cache**, **no Claude
credentials**, **no Gradle cache** — the first `./gradlew assembleDebug` in a fresh VM
downloads the wrapper distribution and dependencies. The Claude in Chrome extension is
installed but signed into nothing, on the same terms as Claude Code itself: the login
happens once per guest and stays there.

**No git or GitHub identity of any kind**, deliberately: no `known_hosts` entry for
github.com, no deploy key, no token, and no `git config` user. The `gh` binary is installed
(section 4) but logged into nothing. The image is shared by every project VM, so anything
more would be a credential handed to all of them. `New-AgentVM.ps1` logs `gh` in inside a
single guest, after boot, only when asked — fed the host's own token over SSH stdin, or
through an interactive `gh auth login` — and never writes a credential to the seed ISO,
which stays attached to the VM and readable from inside it.

## 11. What a VM from this image can do

| Capability | Provided by |
|---|---|
| **React web** (Vite + React + TS) | Node + npm |
| **React Native (Android)** | Temurin 21 (17 also installed), the Android SDK, CMake + Ninja, `build-essential` |
| **Capacitor (Android)** | the same toolchain |
| **Android emulator** | AVD `dev` resumed from the `golden` snapshot on KVM |
| **Screenshot / UI verification loop** | `adb exec-out screencap`, animations already disabled |
| **adb from the Windows host** | `adb-bridge.service` |
| **Browser end-to-end tests** | Playwright with Chromium, Firefox and WebKit already downloaded |
| **Desktop IDE** | VS Code over lossless xrdp |
| **Agent-driven UI work** | Claude Code + the `mobile` MCP server |
| **Agent-driven browser work** | `claude --chrome` against Chrome and the Claude in Chrome extension |

`packer/README.md` has the acceptance checks to run against a freshly built image, including
one real `./gradlew assembleDebug` — the only check that actually exercises the C/C++
toolchain.

## 12. Versions: latest by design

**Every build of this image is meant to ship the newest of everything.** That is the policy,
not an oversight — a fresh VM should get the current Ubuntu, the current Android SDK, the
current VS Code and the current Claude Code, because the whole point of a disposable dev image
is that rebuilding it is how you move forward.

So the defaults resolve "newest" at build time rather than naming a version:

| Component | How it resolves | Result |
|---|---|---|
| Ubuntu ISO | `Build-GoldenImage.ps1` reads the published `SHA256SUMS` and takes the highest point release | current 24.04.x |
| Ubuntu packages | `apt-get upgrade` in `10-desktop-xrdp.sh` | current archive |
| Node | NodeSource `setup_22.x` | newest 22.x |
| SDKMAN | install script from `get.sdkman.io` | current |
| JDKs | newest `-tem` identifier per major in `sdk list java`, for each of `JDK_MAJORS` | newest Temurin 21.x and 17.x |
| Android API + system image | newest API that has a `google_apis;x86_64` image | resolved by the build's pinned `sdkmanager --list` |
| Android build-tools | newest stable with a major <= the resolved API | resolved by the build's pinned `sdkmanager --list` |
| `cmdline-tools` | bootstrapped from a pinned zip, then `sdkmanager --install "cmdline-tools;latest"` | current |
| `platform-tools` (adb), `emulator` | `sdkmanager --install` with no revision | current |
| VS Code | Microsoft `stable` channel | current |
| GitHub CLI | GitHub apt repository, `stable` | current |
| Google Chrome | Google's apt repository, `stable` | current |
| Claude in Chrome extension | `ExtensionInstallForcelist` policy, fetched by Chrome | current Web Store release |
| Chromium | apt, snap fallback | current |
| Playwright | `npm install -g @playwright/test` | current |
| Playwright browsers | `playwright install` for the resolved Playwright version | the builds that version pins |
| Claude Code | `npm install -g @anthropic-ai/claude-code` | current |
| Claude Code extension for VS Code | `code --install-extension anthropic.claude-code` | current Marketplace release |
| `mobile` MCP server | `npx -y @mobilenext/mobile-mcp@latest` | current *at every launch* |
| watchman | newest GitHub release with a Linux zip | current |

Two consequences worth naming, since neither is a bug:

- **Two builds from the same commit are different images.** There is no reproducible-build
  goal here and no attempt at one.
- **The `mobile` MCP server is not versioned by the image at all.** `50-claude.sh` registers
  an `npx … @latest` *command*, not an installed package, so every VM resolves it afresh the
  first time an agent starts the server — including VMs cloned from an image built a year ago.

### Where "latest" needs a guard rail

Two places take the newest thing that *works* rather than the newest thing that exists,
because the naive version breaks the build:

- **The Android API is chosen by system image, not by platform.** Google ships a new
  `platforms;android-NN` before the matching emulator image. Picking the newest platform
  therefore periodically selects an API with nothing bootable: the SDK install succeeds, and
  `avdmanager` fails with "package not available" twenty minutes later. `30-android-sdk.sh`
  resolves the newest API that has a `google_apis;x86_64` system image, so the AVD is always
  buildable.
- **Release candidates are excluded.** The package-id patterns are `$`-anchored, which rejects
  `build-tools;36.0.0-rc1` and preview platforms like `platforms;android-VanillaIceCream`. A
  golden image should not be built against a preview toolchain by accident.
- **build-tools is capped at the resolved API.** Their majors track API levels — the 36.x line
  belongs to API 36 — and the next major ships long before the platform and emulator image it
  belongs to. Uncapped, "newest" pairs build-tools 37 with API 36: not broken, but no AGP will
  select it, so the first project build downloads the right one anyway and the shipped copy is
  dead weight.

One risk this leaves open, stated plainly: a new Android API or AGP can land that React Native
does not support yet, and the next rebuild picks it up. That is the accepted cost of tracking
latest. If it bites, pin the one variable that broke — do not turn the whole image into a
pinned build.

### Pinning, when you actually want it

Every resolver is an override, so a pin is a flag rather than an edit:

| Variable | Default | Pinned example |
|---|---|---|
| `android_api` | *(empty — newest bootable API)* | `-var android_api=35` |
| `android_build_tools` | *(empty — newest on the API's line)* | `-var android_build_tools=35.0.0` |
| `node_major` | 22 | `-var node_major=24` |
| `watchman_version` | *(empty — newest with a Linux zip)* | `-var watchman_version=v2024.11.11.00` |
| `android_cmdline_tools_url` | pinned bootstrap zip | replaced by `cmdline-tools;latest` regardless |
| `avd_name` / `avd_device` / `avd_ram_mb` | `dev` / `pixel_6` / 4096 | |
| `cpus` / `memory` / `disk_size` | 4 / 8192 MB / 61440 MB | |

The Ubuntu ISO is pinned through the wrapper instead, since that is what resolves it:

```powershell
.\Build-GoldenImage.ps1 -UbuntuSeries 24.04                     # default: current 24.04.x
.\Build-GoldenImage.ps1 -IsoUrl <url> -IsoChecksum sha256:<hex>  # an exact ISO
```

### Record what a build produced

Since the versions are a property of the build *date*, the build log is the only record of
them. `30-android-sdk.sh` prints the resolved API and build-tools, `Build-GoldenImage.ps1`
prints the resolved ISO, and each script ends with a `==> versions` block. Save that output
next to the VHDX — when a VM misbehaves months later, "what was in this image" is otherwise
unanswerable without booting it.

Keeping the previous VHDX is the other half of that. `Build-GoldenImage.ps1` builds to a new
filename and refuses to overwrite an image that still has children, so retiring one only when
its last child is gone leaves a known-good fallback — which is the practical answer to a bad
upstream release, rather than trying to reconstruct an old image from a pinned build.

## 13. Disk budget

| | |
|---|---|
| Virtual disk | 60 GB (`disk_size = 61440`) |
| Built VHDX, compacted | 20.7 GB |
| Of which the system image | ~1.5 GB |
| Of which the `golden` snapshot | ~1–2 GB |

Children are differencing disks, so a new VM costs only what it writes.

---

## See also

- `packer/README.md` — building the image, and the two things that most often go wrong
- `runbook.md` — day-to-day operation of a VM
- `host-scripts.md` — the host-side scripts that build, clone and remove VMs
- `linux-vm-on-windows.md` — the design this implements
