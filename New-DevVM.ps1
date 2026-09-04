<#
.SYNOPSIS
    Creates a per-project React Native development VM on Hyper-V from the golden Ubuntu image.

.DESCRIPTION
    Implements section 8.2 of scratch/linux-vm-on-windows.md:

      1. Creates a differencing disk against the immutable golden VHDX (thin clone, seconds).
      2. Creates a Generation 2 VM with nested virtualization enabled, static memory,
         Secure Boot off and checkpoints disabled - all required for KVM inside the guest.
      3. Renders the cloud-init NoCloud seed (user-data / meta-data), builds seed.iso with
         oscdimg and attaches it as a DVD drive.
      4. Starts the VM, waits for a DHCP address, writes a tuned .rdp file and prints the
         connection lines.
      5. With -Repo, offers to log into GitHub inside the guest over an interactive SSH
         session and clone the project.

    Step 5 is deliberately NOT part of first boot. cloud-init runs before anyone can type a
    password, so an unattended clone of a private repo would need a credential shipped in the
    image or written onto the seed ISO - and that ISO stays attached to the VM for its whole
    life and is readable from inside the guest. Doing it interactively afterwards means the
    only thing that ever touches the guest is a token you authorised yourself, and the golden
    image stays free of any GitHub or git identity at all.

    Run from an elevated PowerShell session; the Hyper-V cmdlets require Administrator.

.PARAMETER Name
    Project / VM name, e.g. app-foo. Used as the hostname, the folder under -VmRoot and the
    .rdp file name.

.PARAMETER Repo
    Project to check out into /home/dev/app, AFTER boot, over an interactive SSH session that
    asks first (see -SkipGitHubLogin). Accepts anything `gh repo clone` takes - "owner/repo"
    or a GitHub URL - and falls back to plain `git clone` for a non-GitHub URL.
    Omit to create a VM with an empty ~/app.

.PARAMETER SkipGitHubLogin
    Do not offer the GitHub login and clone. Creates the VM and stops at the connection lines,
    leaving ~/app empty. For unattended runs, and for repos you would rather clone by hand.

.PARAMETER Memory
    Fixed RAM for the guest. Defaults to 10GB, or 6GB when -DeviceSerial is given (no emulator).

.PARAMETER Cpus
    Virtual processor count. Default 4.

.PARAMETER DeviceSerial
    adb serial of a physical phone assigned to this project (section 13). When set, the guest
    skips the emulator and pins itself to that device through the host's adb server.

.PARAMETER Root
    Where images and VMs live. Defaults to $env:DEVVM_ROOT, else C:\Hyper-V. -GoldenVhdx and
    -VmRoot derive from it; set DEVVM_ROOT once (machine scope) to move everything to another
    drive. Must match the -Root used by Build-GoldenImage.ps1 and Remove-DevVM.ps1.

.PARAMETER HostIp
    Address of the Windows host on the DevSwitch subnet, used for ADB_SERVER_SOCKET.
    Only meaningful together with -DeviceSerial.

.EXAMPLE
    .\New-DevVM.ps1 -Name app-foo -Repo you/foo

.EXAMPLE
    .\New-DevVM.ps1 -Name app-game -Repo you/game -DeviceSerial 3A9X0T2K -HostIp 192.168.1.10

.EXAMPLE
    .\New-DevVM.ps1 -Name app-scratch
    Empty ~/app, no GitHub prompt.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,30}$')]
    [string]$Name,

    # The value is interpolated into a remote shell command, so keep it to characters a repo
    # reference actually needs - no quotes, spaces, semicolons or backticks to break out with.
    [ValidatePattern('^[A-Za-z0-9@:._/+-]+$')]
    [string]$Repo,

    [switch]$SkipGitHubLogin,

    [int64]$Memory,

    [ValidateRange(1, 64)]
    [int]$Cpus = 4,

    [string]$DeviceSerial = '',

    [string]$HostIp,

    [string]$Root = $(if ($env:DEVVM_ROOT) { $env:DEVVM_ROOT } else { 'C:\Hyper-V' }),

    [string]$GoldenVhdx = [IO.Path]::Combine($Root, 'golden', 'golden-ubuntu-rn.vhdx'),

    [string]$VmRoot = [IO.Path]::Combine($Root, 'vms'),

    [string]$SwitchName = 'DevSwitch',

    [string]$SshPublicKeyPath = "$HOME\.ssh\id_ed25519.pub",

    # Generated when omitted; printed once at the end for the RDP login.
    [string]$RdpPassword,

    [string]$OscdimgPath = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe',

    [string]$RdpOutputDirectory = $PWD.Path,

    # Seconds to wait for the guest to report a DHCP address.
    [int]$IpTimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- helpers ---

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }

function New-RandomPassword {
    param([int]$Length = 20)
    # Alphanumeric only: the value is substituted into YAML and typed into mstsc.
    $alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = [byte[]]::new($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run from an elevated PowerShell session; the Hyper-V cmdlets require Administrator.'
    }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Question, [bool]$DefaultYes = $true)

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = (Read-Host "$Question $suffix").Trim()
        if (-not $answer) { return $DefaultYes }
        if ($answer -match '^(y|yes)$') { return $true }
        if ($answer -match '^(n|no)$') { return $false }
        Write-Host '    Please answer y or n.' -ForegroundColor Yellow
    }
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 2000
    )

    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($IpAddress, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Wait-ForSsh {
    param([Parameter(Mandatory)][string]$IpAddress, [int]$TimeoutSeconds = 240)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -IpAddress $IpAddress -Port 22) { return $true }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Clear-StaleHostKey {
    <#
        A dev VM lives days and its address comes from DHCP, so the same IP comes back
        attached to a different machine within a week. The host then refuses to connect at
        all - "REMOTE HOST IDENTIFICATION HAS CHANGED", which reads like an attack rather
        than the routine lease reuse it is - and StrictHostKeyChecking=accept-new does not
        help, because the problem is the entry that is already there.

        Only handles unhashed entries, which is what the Windows OpenSSH client writes by
        default (HashKnownHosts is off there). For a hashed file, `ssh-keygen -R <ip>`.
    #>
    param([Parameter(Mandatory)][string]$IpAddress)

    $knownHosts = Join-Path $HOME '.ssh\known_hosts'
    if (-not (Test-Path -LiteralPath $knownHosts)) { return }

    $lines = @(Get-Content -LiteralPath $knownHosts)
    $pattern = '^\[?' + [regex]::Escape($IpAddress) + '[\]:, ]'
    $kept = @($lines | Where-Object { $_ -notmatch $pattern })

    if ($kept.Count -ne $lines.Count) {
        Set-Content -LiteralPath $knownHosts -Value $kept -Encoding ASCII
        Write-Note "removed a stale known_hosts entry for $IpAddress"
    }
}

function Invoke-GuestGitHubSetup {
    <#
        Logs into GitHub inside the guest and clones the project, interactively. Returns
        $true only if the whole thing succeeded, so the caller can tell the operator what
        ~/app actually contains rather than guessing.
    #>
    param(
        [Parameter(Mandatory)][string]$IpAddress,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$SetupScript
    )

    foreach ($tool in 'ssh', 'scp') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Warning "$tool is not on PATH; skipping the checkout. Add the Windows OpenSSH client (Settings > Optional features) and clone by hand."
            return $false
        }
    }

    Write-Step "Waiting for SSH on $IpAddress"
    if (-not (Wait-ForSsh -IpAddress $IpAddress)) {
        Write-Warning "No SSH on $IpAddress after 240 s; skipping the checkout."
        return $false
    }

    Clear-StaleHostKey -IpAddress $IpAddress

    $target  = "dev@$IpAddress"
    $sshOpts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10')

    # sshd answers before cloud-init has finished, and runcmd is what creates ~/app. Waiting
    # here keeps the clone from racing it. `exit 0` because a non-zero cloud-init status
    # (deprecation warnings alone will do it) is not a reason to abandon the checkout.
    Write-Step 'Waiting for first boot to finish'
    & ssh @sshOpts $target 'cloud-init status --wait >/dev/null 2>&1; exit 0'

    $localScript = Join-Path ([IO.Path]::GetTempPath()) ('devvm-github-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sh')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($localScript, ($SetupScript -replace "`r`n", "`n"), $utf8NoBom)

    try {
        & scp @sshOpts $localScript "${target}:/tmp/github-setup.sh"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not copy the setup script to the guest (scp exit $LASTEXITCODE); skipping the checkout."
            return $false
        }

        Write-Host ''
        Write-Step "GitHub login and clone in $IpAddress"
        Write-Note 'gh prints a one-time code and opens a browser flow; answer its prompts here.'
        Write-Host ''

        # -t forces a TTY: without it gh sees a non-interactive stdin and refuses to prompt.
        & ssh @sshOpts -t $target "bash /tmp/github-setup.sh '$Repo'"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "The guest setup script exited $LASTEXITCODE - see the output above. ~/app may be empty or partially set up."
            return $false
        }
        return $true
    }
    finally {
        Remove-Item -LiteralPath $localScript -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForGuestIPv4 {
    param([string]$VMName, [int]$TimeoutSeconds)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $addresses = @()
        try {
            $addresses = @((Get-VMNetworkAdapter -VMName $VMName).IPAddresses)
        } catch {
            # Integration services are not up yet; keep waiting.
        }
        foreach ($address in $addresses) {
            if ($address -match '^\d{1,3}(\.\d{1,3}){3}$' -and $address -notmatch '^169\.254\.') {
                return $address
            }
        }
        Start-Sleep -Seconds 5
    }
    return $null
}

# -------------------------------------------------------------- preflight ---

Assert-Administrator

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'The Hyper-V PowerShell module is not available. Enable the Hyper-V feature first (section 2).'
}

if (-not (Test-Path -LiteralPath $GoldenVhdx)) {
    throw "Golden image not found: $GoldenVhdx. Build it with Packer first (section 8.1)."
}

if (-not (Test-Path -LiteralPath $OscdimgPath)) {
    throw "oscdimg.exe not found: $OscdimgPath. Install the Windows ADK Deployment Tools, or pass -OscdimgPath."
}

if (-not (Test-Path -LiteralPath $SshPublicKeyPath)) {
    throw "SSH public key not found: $SshPublicKeyPath. Pass -SshPublicKeyPath."
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Virtual switch '$SwitchName' does not exist. Create it once (section 2)."
}

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    throw "A VM named '$Name' already exists. Remove it with .\Remove-DevVM.ps1 -Name $Name first."
}

$vmPath = Join-Path $VmRoot $Name
if (Test-Path -LiteralPath $vmPath) {
    throw "Project folder already exists: $vmPath. Remove it before recreating the VM."
}

if (-not $Memory) {
    # Phone-backed VMs run no emulator, so they need markedly less RAM (section 13.3).
    $Memory = if ($DeviceSerial) { 6GB } else { 10GB }
}

if ($DeviceSerial -and -not $HostIp) {
    throw '-DeviceSerial requires -HostIp: the guest talks to the adb server running on the host (section 13.1).'
}

if (-not $RdpPassword) { $RdpPassword = New-RandomPassword }

$sshPublicKey = (Get-Content -LiteralPath $SshPublicKeyPath -Raw).Trim()

Write-Step "Creating dev VM '$Name'"
Write-Note ("memory {0} GB, {1} vCPU, switch {2}" -f ($Memory / 1GB), $Cpus, $SwitchName)
if ($DeviceSerial) {
    Write-Note "render target: physical device $DeviceSerial via adb server tcp:${HostIp}:5037"
} else {
    Write-Note 'render target: AVD emulator, resumed from the golden snapshot'
}

# ----------------------------------------------------- disk, VM, hardware ---

New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

$diskPath = Join-Path $vmPath 'disk.vhdx'
$seedIso  = Join-Path $vmPath 'seed.iso'

Write-Step 'Creating differencing disk'
New-VHD -Path $diskPath -ParentPath $GoldenVhdx -Differencing | Out-Null

Write-Step 'Creating the VM'
New-VM -Name $Name -Generation 2 -MemoryStartupBytes $Memory `
       -VHDPath $diskPath -SwitchName $SwitchName -Path $VmRoot | Out-Null

# Nested virtualization requires static memory and forbids checkpoints (section 10).
Set-VM -Name $Name -StaticMemory -AutomaticStartAction Nothing -AutomaticStopAction Shutdown
Set-VM -Name $Name -CheckpointType Disabled
Set-VMProcessor -VMName $Name -Count $Cpus -ExposeVirtualizationExtensions $true
Set-VMNetworkAdapter -VMName $Name -MacAddressSpoofing On
Set-VMFirmware -VMName $Name -EnableSecureBoot Off

# ------------------------------------------------------ cloud-init seed ---

$userDataTemplate = @'
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
      # No Anthropic credentials here: Claude Code authenticates once per VM against your
      # subscription (run `claude` and log in), and stores its own token under ~/.claude.
      PROJECT=${NAME}
      # Physical device mode (section 12). An empty ANDROID_SERIAL means the emulator.
      ADB_SERVER_SOCKET=${ADB_SERVER_SOCKET}
      ANDROID_SERIAL=${DEVICE_SERIAL}
runcmd:
  # Every entry is a YAML *sequence* (an argv list), not a bare string, and each shell
  # fragment is single-quoted. This is not style. A plain YAML scalar that contains ": "
  # is a mapping, so
  #     - sudo -u dev bash -lc '... || echo "WARNING: no emulator after 180s"'
  # parses as a dict, cc_runcmd cannot shellify a dict, and the module dies with a
  # TypeError that takes *every other line in runcmd* down with it - no ~/app, no
  # emulator, no tmux session. The VM still answers SSH and looks healthy; the only place
  # that says otherwise is `cloud-init status --long` inside the guest. Keep new entries
  # in this form and a colon in a message stays harmless.
  #
  # Just the directory - no clone. cloud-init runs before anyone can authenticate, so an
  # unattended checkout of a private repo would need a credential baked into the image or
  # written onto this seed ISO, which stays attached and readable inside the guest for the
  # life of the VM. The checkout is an interactive step over SSH instead; this only has to
  # exist so the tmux session below has a working directory.
  - [sudo, -u, dev, mkdir, -p, /home/dev/app]
  # Emulator only when no phone is assigned to this VM
  - [sudo, -u, dev, bash, -lc, '[ -z "${DEVICE_SERIAL}" ] && (unset ADB_SERVER_SOCKET; ~/bin/emu -snapshot golden >/tmp/emu.log 2>&1 &) || true']
  # Wait for the emulator to register, but do NOT run `adb tcpip 5555` here. That switches
  # the guest Android's adbd to TCP mode behind qemu's NAT - unreachable from the host
  # either way - and knocks the emulator off this VM's own adb server, after which a local
  # `adb exec-out screencap` writes a zero-byte file. Host access comes from the
  # adb-bridge.service socat unit baked into the image, which needs nothing done here.
  # `timeout` is not optional. adb wait-for-device blocks FOREVER on an emulator that never
  # registers, and it is the second-to-last thing in runcmd - so a failed emulator start does
  # not just cost you the emulator, it wedges cloud-init and the tmux session below never
  # runs. That failure is silent: the VM answers SSH and looks healthy.
  - [sudo, -u, dev, bash, -lc, '[ -z "${DEVICE_SERIAL}" ] && (unset ADB_SERVER_SOCKET; sleep 20; timeout 180 adb wait-for-device || echo "WARNING: no emulator after 180s - see /tmp/emu.log") || true']
  - [sudo, -u, dev, tmux, new, -d, -s, agent, -c, /home/dev/app]
'@

$metaDataTemplate = @'
instance-id: ${NAME}-${INSTANCE}
local-hostname: ${NAME}
'@

# Runs ONCE in the guest, over `ssh -t`, so gh's login prompts reach the operator's terminal.
# Shipped by scp rather than piped into `bash -s`: PowerShell would terminate the piped string
# with CRLF and bash treats the stray \r as part of the last command.
#
# Nothing here is in the golden image on purpose. gh, the GitHub apt repo, the known_hosts
# entry and the token are all installed per VM, at the moment someone asks for them.
$guestGitHubScript = @'
#!/usr/bin/env bash
# Written by New-DevVM.ps1. Interactive: expects a TTY.
set -euo pipefail

REPO="${1:?usage: github-setup.sh <repo>}"
APP=/home/dev/app

if ! command -v gh >/dev/null 2>&1; then
    echo "==> installing the GitHub CLI"
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
fi
gh --version | head -n1

if gh auth status >/dev/null 2>&1; then
    echo "==> already authenticated to GitHub"
else
    echo "==> gh auth login  (answer the prompts below)"
    gh auth login
fi

# Point git itself at the token, so later pushes from inside the VM do not prompt.
gh auth setup-git

# An SSH-form URL needs the host key up front: this runs with a TTY but nobody wants to answer
# "authenticity of host can't be established" mid-clone, and a non-GitHub host would otherwise
# fail outright. Per VM, only for the host actually being cloned from.
case "$REPO" in
    git@*|ssh://*)
        host="$(printf '%s' "$REPO" | sed -E 's|^ssh://||; s|^[^@]*@||; s|[:/].*$||')"
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        touch ~/.ssh/known_hosts && chmod 600 ~/.ssh/known_hosts
        if ! ssh-keygen -F "$host" >/dev/null 2>&1; then
            echo "==> adding ${host} to known_hosts"
            ssh-keyscan -H "$host" >> ~/.ssh/known_hosts 2>/dev/null
        fi
        ;;
esac

if [ -e "${APP}/.git" ]; then
    echo "==> ${APP} is already a git repo; leaving it alone"
else
    echo "==> cloning ${REPO}"
    # runcmd created ~/app empty. git refuses to clone into a non-empty directory but is
    # perfectly happy with an empty one, so there is nothing to clean up first.
    if printf '%s' "$REPO" | grep -qE '(^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$)|github\.com'; then
        gh repo clone "$REPO" "$APP"
    else
        echo "    not a GitHub repo - using plain git"
        git clone "$REPO" "$APP"
    fi
fi

if [ -f "${APP}/package.json" ]; then
    echo "==> npm install"
    cd "$APP"
    npm install
else
    echo "==> no package.json; skipping npm install"
fi

echo "==> checkout ready in ${APP}"
'@

# A phone-backed guest points its adb client at the host's server; an emulator guest keeps
# the local default (section 13.1).
$adbServerSocket = if ($DeviceSerial) { "tcp:${HostIp}:5037" } else { '' }
$substitutions = [ordered]@{
    '${NAME}'              = $Name
    '${SSH_PUBKEY}'        = $sshPublicKey
    '${RDP_PASSWORD}'      = $RdpPassword
    '${ADB_SERVER_SOCKET}' = $adbServerSocket
    '${DEVICE_SERIAL}'     = $DeviceSerial
    '${INSTANCE}'          = [guid]::NewGuid().ToString('N').Substring(0, 8)
}

$userData = $userDataTemplate
$metaData = $metaDataTemplate
foreach ($key in $substitutions.Keys) {
    $userData = $userData.Replace($key, [string]$substitutions[$key])
    $metaData = $metaData.Replace($key, [string]$substitutions[$key])
}

Write-Step 'Building cloud-init seed ISO'
$seedDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cidata-$Name-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $seedDir -Force | Out-Null
try {
    # cloud-init wants LF line endings and no BOM.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $seedDir 'user-data'), ($userData -replace "`r`n", "`n"), $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $seedDir 'meta-data'), ($metaData -replace "`r`n", "`n"), $utf8NoBom)

    # NoCloud looks for a filesystem labelled CIDATA.
    $oscdimgOutput = & $OscdimgPath -n -m -d -lCIDATA $seedDir $seedIso
    if ($LASTEXITCODE -ne 0) {
        throw "oscdimg failed with exit code ${LASTEXITCODE}: $oscdimgOutput"
    }
} finally {
    Remove-Item -LiteralPath $seedDir -Recurse -Force -ErrorAction SilentlyContinue
}

Add-VMDvdDrive -VMName $Name -Path $seedIso

# Adding a DVD drive can take over the Gen 2 boot order; put the disk back in front.
$bootDisk = Get-VMHardDiskDrive -VMName $Name
Set-VMFirmware -VMName $Name -FirstBootDevice $bootDisk

# --------------------------------------------------------- start and wait ---

Write-Step 'Starting the VM'
Start-VM -Name $Name | Out-Null

Write-Step "Waiting for a DHCP address, up to $IpTimeoutSeconds s"
$ip = Wait-ForGuestIPv4 -VMName $Name -TimeoutSeconds $IpTimeoutSeconds

if (-not $ip) {
    Write-Warning "No address reported within $IpTimeoutSeconds s. The VM is running - check the Hyper-V console or your DHCP leases, then write the .rdp file by hand."
    Write-Host ''
    Write-Host "VM:       $Name"
    Write-Host "RDP user: dev"
    Write-Host "RDP pass: $RdpPassword"
    return
}

# ------------------------------------------------------------- .rdp file ---

# Lossless settings from section 6: 32-bit colour, no compression, smart sizing off,
# so one guest pixel maps to one host pixel.
$rdpPath = Join-Path $RdpOutputDirectory "$Name.rdp"
$rdpContent = @"
full address:s:$ip
username:s:dev
screen mode id:i:2
smart sizing:i:0
desktopscalefactor:i:100
session bpp:i:32
connection type:i:6
networkautodetect:i:0
bandwidthautodetect:i:0
compression:i:0
bitmapcachepersistenable:i:0
disable wallpaper:i:0
allow font smoothing:i:1
allow desktop composition:i:1
disable full window drag:i:0
disable menu anims:i:0
disable themes:i:0
authentication level:i:0
redirectclipboard:i:1
audiomode:i:2
"@
Set-Content -LiteralPath $rdpPath -Value $rdpContent -Encoding ASCII

# ----------------------------------------------------------- connect info ---

Write-Host ''
Write-Step "'$Name' is up at $ip"
Write-Host ''
Write-Host "  SSH + agent : ssh dev@$ip -t tmux attach"
Write-Host "  RDP         : $rdpPath   (user dev / password $RdpPassword)"
if ($DeviceSerial) {
    Write-Host "  Device      : $DeviceSerial via the host adb server, tcp:${HostIp}:5037"
    Write-Host "  Screen      : scrcpy -s $DeviceSerial          # on the host, over USB"
} else {
    Write-Host "  Emulator    : adb connect ${ip}:5555            # on the host"
    # NOT `exec-out screencap -p > screen.png`. PowerShell's `>` is a text redirect: it
    # decodes the PNG bytes as text and re-encodes them as UTF-8 with a BOM, and the file
    # that lands is not a PNG. screencap-to-file plus pull is byte-exact in every shell.
    Write-Host "  Screenshot  : adb -s ${ip}:5555 shell screencap -p /sdcard/s.png; adb -s ${ip}:5555 pull /sdcard/s.png screen.png"
}
Write-Host "  Metro       : http://${ip}:8081"
Write-Host ''

# ------------------------------------------------- GitHub login and clone ---

$repoReady = $false
if ($Repo -and -not $SkipGitHubLogin) {
    Write-Host "  Project     : $Repo" -ForegroundColor Cyan
    Write-Note 'Logging in installs the GitHub CLI in this VM and stores a token in it.'
    Write-Note 'Nothing is written to the golden image, and no credential goes on the seed ISO.'
    Write-Host ''
    if (Read-YesNo -Question '  Log into GitHub in this VM and clone the project now?') {
        $repoReady = Invoke-GuestGitHubSetup -IpAddress $ip -Repo $Repo -SetupScript $guestGitHubScript
    }
    else {
        Write-Note 'Skipped. ~/app is empty.'
    }
    Write-Host ''
}

Write-Step "'$Name' summary"
if ($Repo -and $repoReady) {
    Write-Note "~/app has $Repo checked out, dependencies installed."
}
elseif ($Repo) {
    Write-Note "~/app is EMPTY. To finish the checkout: ssh dev@$ip -t ""bash /tmp/github-setup.sh '$Repo'"""
    Write-Note "Or clone it yourself over agent forwarding: ssh -A dev@$ip"
}
else {
    Write-Note '~/app is empty - no -Repo was given.'
}
Write-Note 'The emulator is still resuming from the golden snapshot; give it a few seconds.'
Write-Note "Log the agent in once in this VM: ssh dev@$ip -t claude   (then /login, subscription account)."
