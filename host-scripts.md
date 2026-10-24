# Host scripts

The PowerShell scripts that run on the Windows host to build, create, operate and remove
dev VMs. One image, many clones: `Build-GoldenImage.ps1` makes the image once, the other
four work on individual VMs cloned from it.

For the design see `linux-vm-on-windows.md`; for the step-by-step see `runbook.md`; for
what is inside the image see `golden-image-contents.md`; for the Packer build itself see
`packer/README.md`. Each script also carries full comment-based help:
`Get-Help .\New-AgentVM.ps1 -Full`.

| Script | Lives in | Does | Needs elevation |
|---|---|---|---|
| `packer\Build-GoldenImage.ps1` | `packer\` | Builds the golden VHDX with Packer, then compacts and write-protects it | yes |
| `New-AgentVM.ps1` | repo root | Clones a project VM from the golden image, boots it, writes its `.rdp` file, optionally clones the repo | yes |
| `Remove-AgentVM.ps1` | repo root | Stops and deletes a project VM and its files | yes |
| `Get-AgentVMPassword.ps1` | repo root | Prints a VM's RDP password | no |
| `Set-AgentVMPassword.ps1` | repo root | Sets a new RDP password over SSH | only for the address lookup |

---

## Shared conventions

**Where things live.** Every script takes `-Root`, defaulting to `$env:AGENTVM_ROOT` and then
`C:\Hyper-V`. Everything else derives from it:

```
<Root>\golden\golden-ubuntu-rn.vhdx     the golden image, read-only
<Root>\golden\build\                    Packer's scratch output; deleted after a build
<Root>\vms\<Name>\disk.vhdx             differencing disk, parent = the golden image
<Root>\vms\<Name>\seed.iso              cloud-init seed; stays attached for the VM's life
<Root>\vms\<Name>\Virtual Machines\     Hyper-V's own config
.\<Name>.rdp                            in the directory New-AgentVM.ps1 was run from
```

The RDP password is in none of these files. On the host it is only in Windows Credential
Manager, under `TERMSRV/<address>` for the `.rdp` file and `agent-vm:<Name>` for
`Get-AgentVMPassword.ps1`.

To move all of it to another drive, set the variable once at machine scope and open a new
shell, or pass the same `-Root` to every script:

```powershell
[Environment]::SetEnvironmentVariable('AGENTVM_ROOT', 'E:\Hyper-V', 'Machine')
```

**Names.** `-Name` is the VM name, the guest hostname, the folder under `vms\` and the
`.rdp` file name. Letters, digits and hyphens, up to 31 characters, starting with a letter
or digit.

**Elevation.** The Hyper-V cmdlets need Administrator, so anything that creates, inspects
or removes a VM runs from an elevated PowerShell. The two password scripts are the
exception: they work on files and SSH, and only `Set-AgentVMPassword.ps1` without
`-IpAddress` touches Hyper-V.

**Guards.** The scripts refuse rather than guess whenever the golden image could be harmed.
Build will not overwrite an image that still has differencing children. Remove will not
delete a disk that is not a differencing child inside the project folder, or that is
another VM's parent. New will not reuse a VM name or a project folder that already exists.

**Output.** Progress lines are prefixed with `==>`, details with four spaces. Passwords are
printed in the clear at the end of a run; the VMs are reachable only on the local switch,
so they are short and treated as convenience, not secrets.

---

## `Build-GoldenImage.ps1`

Run from `packer\`, in an elevated shell. 30 to 50 minutes.

```powershell
.\Build-GoldenImage.ps1
.\Build-GoldenImage.ps1 -GoldenPath C:\Hyper-V\golden\golden-ubuntu-rn-2026-09.vhdx   # upgrade, side by side
.\Build-GoldenImage.ps1 -Root E:\Hyper-V                                              # another drive
.\Build-GoldenImage.ps1 -SkipBuild                                                    # redo the post-steps only
.\Build-GoldenImage.ps1 -KeyInterval 250ms                                            # GRUB command keeps mistyping
.\Build-GoldenImage.ps1 -IsoUrl <url> -IsoChecksum sha256:<hex>                       # an exact Ubuntu ISO
```

**What it does**

1. Preflight: elevation, `packer` on PATH, the `DevSwitch` switch, an ISO tool (adds
   `oscdimg` to PATH for the run if none is found), the Packer template, your SSH public
   key, and that the target image either does not exist or may be replaced.
2. If a VM with the build name is left over from an interrupted run, asks to delete it,
   turning it off by force if Hyper-V has it wedged in a transitional state. Clears the
   previous build directory.
3. Resolves the current Ubuntu point release of `-UbuntuSeries` from the published
   checksums, so the ISO pin cannot go stale.
4. `packer init`, `packer validate` (catches a malformed autoinstall config in a second),
   `packer build`.
5. Moves the exported VHDX to `-GoldenPath`, compacts it with `Optimize-VHD`, marks it
   read-only, deletes the build directory.

The install is unattended. If the VM console shows the installer asking questions, the
build has already failed; see `packer/README.md`, "The installer is asking me questions".

**Parameters**

| Parameter | Default | Meaning |
|---|---|---|
| `-Root` | `$env:AGENTVM_ROOT` or `C:\Hyper-V` | Base for `-GoldenPath` and `-BuildDirectory` |
| `-GoldenPath` | `<Root>\golden\golden-ubuntu-rn.vhdx` | Where the finished image lands. Must match `New-AgentVM.ps1 -GoldenVhdx` |
| `-BuildDirectory` | `<Root>\golden\build` | Packer's output directory, deleted afterwards |
| `-PackerDirectory` | the script's own folder | Where `ubuntu-rn.pkr.hcl` is |
| `-SwitchName` | `DevSwitch` | Hyper-V switch the build VM attaches to |
| `-VmName` | `golden-ubuntu-rn` | Name of the temporary build VM |
| `-OscdimgPath` | the Windows ADK default path | Used only when no ISO tool is on PATH |
| `-UbuntuSeries` | `24.04` | Series whose current point release is built |
| `-IsoUrl`, `-IsoChecksum` | resolved | Build an exact ISO instead |
| `-KeyInterval` | `100ms` | Per-keystroke delay for the GRUB boot command |
| `-Replace` | off | Allow overwriting an existing image that has no children |
| `-Force` | off | Delete a leftover build VM without asking |
| `-SkipBuild` | off | Only move, compact and protect an existing build output |
| `-WhatIf` | | Supported for the destructive steps |

**Refuses when** the image exists and `-Replace` was not given, or it exists and any VM
uses it as a differencing parent. An upgrade goes to a new filename; the old image stays
until its last child is removed.

---

## `New-AgentVM.ps1`

Run from the repo root, in an elevated shell. About two minutes to a running VM.

```powershell
.\New-AgentVM.ps1 -Name app-foo -Repo you/foo                       # offers your GitHub + Claude logins, then clones
.\New-AgentVM.ps1 -Name app-foo -Repo you/foo -SkipGitHubLogin -SkipClaudeLogin   # no prompts, no credentials; ~/app stays empty
.\New-AgentVM.ps1 -Name app-scratch                                 # no repo at all
.\New-AgentVM.ps1 -Name app-bar -Repo you/bar -DeviceSerial 3A9X0T2K -HostIp 192.168.1.10   # phone, no emulator
.\New-AgentVM.ps1 -Name app-foo2 -Repo you/foo -GoldenVhdx C:\Hyper-V\golden\golden-ubuntu-rn-2026-09.vhdx
```

**What it does**

1. Preflight: elevation, the Hyper-V module, the golden image, `oscdimg`, your SSH public
   key, the switch, and that neither the VM name nor the project folder exists yet.
2. Offers this host's logins, each a separate yes/no with its own `-Skip` switch: the
   GitHub token `gh` holds here (plus your global git identity), and a long-lived Claude
   **subscription** token from `claude setup-token`, cached at `-ClaudeTokenPath` and
   minted on first use. Asked now so the build below runs uninterrupted; delivered in
   step 7. Each prompt spells out where the credential ends up and what it shares.
3. Creates a differencing disk against the golden image and a Generation 2 VM with static
   memory, nested virtualization, MAC spoofing, Secure Boot off and checkpoints disabled.
   All of that is required for KVM inside the guest.
4. Renders the cloud-init seed: hostname, the `dev` user with your SSH key and passwordless
   sudo, `~/.env` with the project name and adb settings, and a `runcmd` that creates
   `~/app` and starts the emulator from the golden snapshot (emulator VMs only); `runcmd`
   runs only once. No password: the seed stays attached and readable inside the guest.
   Builds `seed.iso` and attaches it as a DVD drive, then puts the disk back first in the
   boot order.
5. Starts the VM, polls for a DHCP address, and writes `<Name>.rdp` with lossless settings.
6. Once SSH answers and cloud-init has finished, sets the RDP password by calling
   `Set-AgentVMPassword.ps1`: Unix and VNC password in the guest, which starts the agent
   desktop and with it the `tmux` session named `agent`, and Credential Manager on the
   host, so the `.rdp` file opens straight onto the agent desktop. Then prints the
   connection lines: SSH with the tmux session, RDP, the emulator's adb address or the
   phone's serial, a screenshot command, and the Metro URL.
7. Copies `agentvm-setup.sh` to `/tmp` in the guest and pipes the accepted credentials to
   it on stdin (never as arguments):
   `gh auth login --with-token`, `gh auth setup-git`,
   `git config --global user.*`, and the Claude token into `~/.claude/settings.json` as
   `env.CLAUDE_CODE_OAUTH_TOKEN`, which logs in the CLI and the VS Code extension alike.
8. With `-Repo` and without `-SkipGitHubLogin`: if the GitHub token went over, clones into
   `~/app` and runs `npm install` straight away. Otherwise asks whether to log into GitHub
   in the guest now, and runs the same script over `ssh -t` so `gh auth login` can prompt,
   giving that VM a token of its own. The script stays at `/tmp/agentvm-setup.sh` in the
   guest, so a declined or failed run can be finished later with the command the summary
   prints.

No password and nothing GitHub- or Claude-related goes into the golden image or onto the seed ISO. The seed
ISO stays attached and readable inside the guest, which is why none of this is part of first
boot. A copied GitHub token is shared with the host: revoking it logs both out. The Claude
token overrides `/login` in that VM; delete the `env` entry from the settings file to switch
accounts there.

**Parameters**

| Parameter | Default | Meaning |
|---|---|---|
| `-Name` | required | VM name, hostname, folder and `.rdp` name |
| `-Repo` | none | Anything `gh repo clone` takes, or a git URL for a non-GitHub host |
| `-SkipGitHubLogin` | off | Never copy the gh token, never offer the login, never clone |
| `-SkipClaudeLogin` | off | Never offer the Claude token |
| `-ClaudeTokenPath` | `~\.agent-vm\claude-oauth-token` | Cached `claude setup-token` token; created on first use, your account only |
| `-Memory` | 10 GB, or 6 GB with `-DeviceSerial` | Static RAM |
| `-Cpus` | 4 | Virtual processors |
| `-DeviceSerial` | none | adb serial of a phone; skips the emulator |
| `-HostIp` | none | Host address on the switch subnet; required with `-DeviceSerial` |
| `-Root` | `$env:AGENTVM_ROOT` or `C:\Hyper-V` | Base for `-GoldenVhdx` and `-VmRoot` |
| `-GoldenVhdx` | `<Root>\golden\golden-ubuntu-rn.vhdx` | Parent image |
| `-VmRoot` | `<Root>\vms` | Where the project folder is created |
| `-SwitchName` | `DevSwitch` | Hyper-V switch |
| `-SshPublicKeyPath` | `~\.ssh\id_ed25519.pub` | Key installed on the `dev` account |
| `-RdpPassword` | generated, 8 chars | Password for `dev`; printed at the end |
| `-OscdimgPath` | the Windows ADK default path | Builds `seed.iso` |
| `-RdpOutputDirectory` | current directory | Where `<Name>.rdp` is written |
| `-IpTimeoutSeconds` | 180 | How long to wait for a DHCP address |

**If no address arrives** within the timeout, the VM is left running and the password is
printed so the `.rdp` file can be written by hand. Check the Hyper-V console and that the
switch is bound to the right NIC.

---

## `Remove-AgentVM.ps1`

Run from the repo root, in an elevated shell.

```powershell
.\Remove-AgentVM.ps1 -Name app-foo               # asks first
.\Remove-AgentVM.ps1 -Name app-foo -Force        # scripted
.\Remove-AgentVM.ps1 -Name app-foo -KeepFiles    # unregister the VM, keep the folder and disk
.\Remove-AgentVM.ps1 -Name app-foo -WhatIf
```

**What it does**

1. Finds the VM, the project folder and the `.rdp` file. If none exist, says so and stops.
2. Checks every disk attached to the VM: it must be a differencing disk inside the project
   folder, and no other VM may use it as a parent.
3. Reports what will go, including the folder size, and asks for confirmation unless
   `-Force`.
4. Asks the guest to shut down, waits up to `-ShutdownTimeoutSeconds`, then turns it off.
   Removes any checkpoints and waits for the merge. Removes the VM from Hyper-V.
5. Deletes the project folder, retrying while Hyper-V still holds the disk open, then the
   `.rdp` file and the Credential Manager entries `TERMSRV/<address>` for the address in
   that file and the address the running VM reported. DHCP may give the address to the
   next VM, and a stale entry would log in with this one's password.

**Parameters**

| Parameter | Default | Meaning |
|---|---|---|
| `-Name` | required | The VM to remove |
| `-Root` | `$env:AGENTVM_ROOT` or `C:\Hyper-V` | Base for `-VmRoot` |
| `-VmRoot` | `<Root>\vms` | Where the project folder is |
| `-RdpOutputDirectory` | current directory | Where the `.rdp` file was written |
| `-KeepFiles` | off | Unregister only; leave the folder on disk |
| `-Force` | off | No confirmation prompt |
| `-ShutdownTimeoutSeconds` | 60 | Grace period before the VM is turned off |

**Refuses when** a disk lives outside the project folder, is not a differencing disk, or
is some other VM's parent. Those cases are removed by hand, because the disk may hold data
that exists nowhere else.

---

## `Get-AgentVMPassword.ps1`

Run from the repo root. No elevation.

```powershell
.\Get-AgentVMPassword.ps1 -Name app-foo
.\Get-AgentVMPassword.ps1 -Name app-foo | Set-Clipboard
```

**What it does.** Prints the RDP password of the `dev` account, read from Windows
Credential Manager (`agent-vm:<Name>`), where `Set-AgentVMPassword.ps1` saves every password
it sets, the first one included. Credential Manager entries belong to the Windows user that
wrote them, so run it as the same user that created the VM. `cmdkey` can only write, so the
script reads the entry through the `CredRead` API.

VMs created before passwords moved off the seed ISO are still read: from
`rdp-password.txt` in the project folder if an earlier `Set-AgentVMPassword.ps1` wrote one,
else from the `chpasswd` entry on `seed.iso`, scanned as bytes rather than mounted.

Only the password goes to the pipeline; the source it came from goes to the host stream.

**Parameters**

| Parameter | Default | Meaning |
|---|---|---|
| `-Name` | required | The VM |
| `-Root` | `$env:AGENTVM_ROOT` or `C:\Hyper-V` | Base for `-VmRoot` |
| `-VmRoot` | `<Root>\vms` | Where the project folder is |
| `-User` | `dev` | Account to look up |

**Fails when** the project folder is missing, or no password is saved for the VM in
Credential Manager and there is no older record either. `Set-AgentVMPassword.ps1` is the
way forward.

---

## `Set-AgentVMPassword.ps1`

Run from the repo root. Elevation only when the VM's address has to be looked up.

```powershell
.\Set-AgentVMPassword.ps1 -Name app-foo                                   # generates one, prints it
.\Set-AgentVMPassword.ps1 -Name app-foo -Password hunter2
.\Set-AgentVMPassword.ps1 -Name app-foo -Password hunter2 -IpAddress 192.168.1.42   # unelevated
```

**What it does**

1. Preflight: `ssh` on PATH and the project folder. Without `-IpAddress`, also elevation,
   the Hyper-V module, that the VM exists and is running, and that it has reported an
   IPv4 address.
2. Generates an 8-character password if none was given, from the same unambiguous
   alphabet `New-AgentVM.ps1` uses.
3. Runs `chpasswd` in the guest over SSH with your key and passwordless sudo. The new
   value goes over stdin, never on a command line, and the guest strips the carriage
   return PowerShell appends to piped text and the UTF-8 byte order mark it puts in front
   when the console's input encoding is UTF-8.
4. Writes the agent desktop's VNC password (`~/.vnc/passwd`). If the desktop is not
   running - on a new VM it cannot start before it has a password - starts it. If it is,
   also overwrites the copy the running Xvnc reads, which it re-reads on every connection:
   the change applies without restarting the desktop or the agent in it. Only the first 8
   characters count there.
5. Unless `-NoRecord`, saves the password in Credential Manager as `TERMSRV/<address>`,
   which the `.rdp` file logs in with, and `agent-vm:<Name>`, which
   `Get-AgentVMPassword.ps1` reads, and deletes an `rdp-password.txt` left by an earlier
   version. Prints the password.

`New-AgentVM.ps1` calls this script for every new VM, so it is also how the first password
is set. None is ever written to a file or to the seed ISO.

**Parameters**

| Parameter | Default | Meaning |
|---|---|---|
| `-Name` | required | The VM |
| `-Password` | generated | 1 to 64 letters, digits or `!#%+,./:=?@^_~-`; no spaces or quotes, because `cmdkey` gets it on its command line |
| `-IpAddress` | looked up via Hyper-V | Guest address; skips the lookup and the elevation |
| `-Root` | `$env:AGENTVM_ROOT` or `C:\Hyper-V` | Base for `-VmRoot` |
| `-VmRoot` | `<Root>\vms` | Where the project folder is |
| `-User` | `dev` | Account to change |
| `-NoRecord` | off | Change the guest only and leave Credential Manager alone |

**Fails when** SSH cannot log in. The usual causes are a VM that is not up, a key that is
not the one on the `dev` account, or a stale `known_hosts` entry after a DHCP lease was
reused. The last is cleared with `ssh-keygen -R <ip>`. The password is unchanged in every
failure case.

---

## Typical sequences

First time on a host:

```powershell
cd packer
.\Build-GoldenImage.ps1
cd ..
.\New-AgentVM.ps1 -Name smoke            # verify the image (runbook §3)
.\Remove-AgentVM.ps1 -Name smoke -Force
```

A new project:

```powershell
.\New-AgentVM.ps1 -Name app-foo -Repo you/foo
mstsc .\app-foo.rdp
```

Forgot the password, or want a different one:

```powershell
.\Get-AgentVMPassword.ps1 -Name app-foo
.\Set-AgentVMPassword.ps1 -Name app-foo
```

Toolchain upgrade, without touching running VMs:

```powershell
cd packer
.\Build-GoldenImage.ps1 -GoldenPath C:\Hyper-V\golden\golden-ubuntu-rn-2026-09.vhdx
cd ..
.\New-AgentVM.ps1 -Name app-foo2 -Repo you/foo -GoldenVhdx C:\Hyper-V\golden\golden-ubuntu-rn-2026-09.vhdx
.\Remove-AgentVM.ps1 -Name app-foo       # once app-foo2 has taken over
```

Done with a project:

```powershell
.\Remove-AgentVM.ps1 -Name app-foo
```
