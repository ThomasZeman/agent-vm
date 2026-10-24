# agent-vm

Disposable Ubuntu VMs on a Windows 11 Hyper-V host, built for running Claude Code agent loops in isolation while
I can still watch what the agent is doing over Remote Desktop.

I run my agents unattended for hours. Doing that on my development machine means every loop has to tiptoe around
my working tree, and a session with `--dangerously-skip-permissions` is a risk to everything on the disk. Giving
each project its own VM removes both problems: the agent can do whatever it wants inside the guest, and the worst
case is that I delete the VM and create a new one in about two minutes.

This repo contains the scripts I use for that. The host is my Ryzen workstation with 64GB of RAM running Windows 11
Pro, and the guests run Ubuntu 24.04 LTS with XFCE. The sibling repo `runner-vm` does the same job with a Windows
guest, for the loops that have to run on Windows.

## How it works

There are two stages. First, Packer builds a golden image once: an unattended Ubuntu install with the desktop, the
toolchains, a browser, the Android emulator and Claude Code already in it. Then every project gets its own VM, which
is only a [differencing disk](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/manage-hyper-v-virtual-hard-disks)
on top of that image plus a small [cloud-init](https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html)
seed ISO which sets the hostname, the user and the SSH key.

```mermaid
flowchart LR
    packer(Build-GoldenImage.ps1 - Packer, 30 to 50 min) --> golden(golden-ubuntu-rn.vhdx - read-only)
    golden --> vm1(app-foo - disk.vhdx + seed.iso)
    golden --> vm2(app-bar - disk.vhdx + seed.iso)
    golden --> vm3(app-baz - disk.vhdx + seed.iso)
```

Because the golden image is never modified, a new VM costs seconds of disk work and only grows by what the project
writes. The image name still carries "rn" from where this started: parallel React Native development, with one
Android emulator per project.

Each VM gets:

- A `dev` user with passwordless sudo. SSH accepts my key only, and RDP uses a generated password.
- XFCE and xrdp, set to lossless 32-bit color so I can judge colors and fonts from the Windows desktop.
- Node LTS, Temurin JDK 21 (17 alongside), the Android SDK and an emulator that resumes from a snapshot on KVM.
- VS Code, Google Chrome with the Claude in Chrome extension, Chromium and Playwright with its browsers.
- Claude Code (CLI and VS Code extension) and the GitHub CLI, both logged into nothing.

It is worth mentioning that no credentials are part of the image or the seed ISO, not even a password. The image is
shared by every VM, and the seed ISO stays attached to the VM and is readable from inside it. `New-AgentVM.ps1` sets
the RDP password over SSH after the VM has booted, and hands over the GitHub and Claude logins the same way, only
when I ask it to. The password Packer uses during the image build is locked before the image is exported.

## Requirements

- Windows 11 Pro with Hyper-V, and AMD-V or VT-x enabled in the BIOS. The emulator needs nested virtualization.
- An external Hyper-V switch called `DevSwitch`, so each VM gets an address on the LAN.
- [Packer](https://developer.hashicorp.com/packer), `oscdimg` from the Windows ADK, and Android platform-tools.
- An SSH key pair at `~/.ssh/id_ed25519`.
- About 70GB free for the image build, plus space for each VM's own disk.

All commands need an elevated PowerShell, apart from `Get-AgentVMPassword.ps1`.

## Getting started

1. Build the golden image. This runs unattended and takes 30 to 50 minutes, most of it the Android system image
   download and the first boot of the emulator.

   ```powershell
   cd packer
   .\Build-GoldenImage.ps1
   cd ..
   ```

2. Create a VM for a project. It is running about two minutes later, and the script writes an `.rdp` file into
   the current directory.

   ```powershell
   .\New-AgentVM.ps1 -Name app-foo -Repo you/foo
   ```

3. Open the `.rdp` file to see the agent desktop, or attach to the agent's tmux session over SSH. Both show the
   same session.

   ```powershell
   mstsc .\app-foo.rdp
   ssh dev@<vm-ip> -t tmux attach -t agent
   ```

4. Stop the VM when it is not needed and remove it when the project is done.

   ```powershell
   Stop-VM -Name app-foo
   .\Remove-AgentVM.ps1 -Name app-foo
   ```

The RDP password is printed once when the VM is created and saved in Windows Credential Manager, so the `.rdp` file
opens without asking for it. It is not stored in any file. `Get-AgentVMPassword.ps1 -Name app-foo` reads it back
from Credential Manager, and `Set-AgentVMPassword.ps1` replaces it.

By default, images and VMs live under `C:\Hyper-V`. To use another drive, set `AGENTVM_ROOT` once, or pass the same
`-Root` to every script.

## Watching the agent

The point of the desktop is that I can see what the agent does, including the browser it drives. This needed more
than xrdp. An xrdp login creates a new desktop for that login only, and anything started before it, such as a tmux
session opened at boot or over SSH, has no display at all. A headed browser launched from there either fails or
runs headless, and there is nothing to watch.

Each VM therefore runs one desktop that exists from boot, whether or not anyone is connected:

```mermaid
flowchart LR
    systemd(systemd at boot) --> vnc(TigerVNC - XFCE on display :1)
    vnc --> tmux(tmux session agent - DISPLAY :1)
    tmux --> browser(browser the agent opens)
    rdp(.rdp file - xrdp Agent desktop) --> vnc
    ssh(ssh - tmux attach -t agent) --> tmux
```

TigerVNC only listens on the VM's loopback interface, and xrdp connects RDP to it. Closing the RDP window leaves the
desktop, the agent and its browser running. The tmux session is an empty shell when the VM starts; I start the agent
in it myself.

## Capacity

The emulator, not the agent, decides how many VMs fit on a host. Memory has to be static, because Hyper-V does not
allow dynamic memory together with nested virtualization.

| VM | vCPU | RAM |
| --- | --- | --- |
| Android emulator available (default) | 4 | 10GB |
| With a physical phone instead (`-DeviceSerial`) | 4 | 6GB |

On my 64GB host, this works out at about five VMs running at the same time after leaving room for Windows. I keep
more than that created, and only start the ones I am working on.

The emulator is not running by default. The agent starts it when a task needs it, and it opens as a window on the
agent desktop. On my host the VM's memory use went from 0.8GB to 5.8GB when it started. `New-AgentVM.ps1
-StartEmulator` starts it with the desktop at every boot instead, for projects that need it all the time.

## Documentation

| Document | Content |
| --- | --- |
| [linux-vm-on-windows.md](linux-vm-on-windows.md) | The design and the reasoning behind it |
| [packer/README.md](packer/README.md) | Building the golden image, and what goes wrong |
| [golden-image-contents.md](golden-image-contents.md) | Everything inside the image, and what is left out on purpose |
| [host-scripts.md](host-scripts.md) | Every host script and parameter |
| [runbook.md](runbook.md) | Every command, on the host and in the guest |

## Known limitations

This is work in progress, and some parts are not finished yet:

- RDP passwords have at most 8 characters, because VNC authentication, which guards the agent desktop, ignores
  everything after the 8th. The VMs are only reachable on my local network, and I never type the password, so I
  accept this.
- The emulator shows an info dialog about running under nested virtualization each time it starts. It does not
  block adb, but it stays on the desktop until someone closes it.
- There is no GPU acceleration in the guests. The emulator renders with SwiftShader, which is fine for app UIs and
  too slow for games.

(Note: Everything here has only been tested on one host, an AMD Ryzen machine with Windows 11 Pro)
