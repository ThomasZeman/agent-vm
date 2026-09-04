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

    Run from an elevated PowerShell session; the Hyper-V cmdlets require Administrator.

.PARAMETER Name
    Project / VM name, e.g. app-foo. Used as the hostname, the folder under -VmRoot and the
    .rdp file name.

.PARAMETER Repo
    Git URL cloned to /home/dev/app at first boot. Omit to create a VM with no project checkout.

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
    .\New-DevVM.ps1 -Name app-foo -Repo git@github.com:you/foo.git

.EXAMPLE
    .\New-DevVM.ps1 -Name app-game -Repo git@github.com:you/game.git -DeviceSerial 3A9X0T2K -HostIp 192.168.1.10
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,30}$')]
    [string]$Name,

    [string]$Repo,

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
  - ${CLONE_CMD}
  - ${INSTALL_CMD}
  # Emulator only when no phone is assigned to this VM
  - sudo -u dev bash -lc '[ -z "${DEVICE_SERIAL}" ] && (unset ADB_SERVER_SOCKET; ~/bin/emu -snapshot golden >/tmp/emu.log 2>&1 &) || true'
  # Wait for the emulator to register, but do NOT run `adb tcpip 5555` here. That switches
  # the guest Android's adbd to TCP mode behind qemu's NAT - unreachable from the host
  # either way - and knocks the emulator off this VM's own adb server, after which a local
  # `adb exec-out screencap` writes a zero-byte file. Host access comes from the
  # adb-bridge.service socat unit baked into the image, which needs nothing done here.
  - sudo -u dev bash -lc '[ -z "${DEVICE_SERIAL}" ] && (unset ADB_SERVER_SOCKET; sleep 20 && adb wait-for-device) || true'
  - sudo -u dev tmux new -d -s agent -c /home/dev/app
'@

$metaDataTemplate = @'
instance-id: ${NAME}-${INSTANCE}
local-hostname: ${NAME}
'@

# A phone-backed guest points its adb client at the host's server; an emulator guest keeps
# the local default (section 13.1).
$adbServerSocket = if ($DeviceSerial) { "tcp:${HostIp}:5037" } else { '' }
$cloneCmd   = if ($Repo) { "sudo -u dev git clone $Repo /home/dev/app" } else { 'sudo -u dev mkdir -p /home/dev/app' }
# The no-repo branch still has to emit a *command*. Plain 'true' renders as the bare YAML
# scalar `- true`, which the parser hands to cloud-init as the boolean True, not a string -
# and shellify() then dies with "Unable to shellify type 'bool'" and discards the WHOLE
# runcmd list, so the emulator, adb tcpip and the tmux session never start either. '/bin/true'
# is unambiguously a string to YAML and a no-op to the shell.
$installCmd = if ($Repo) { "sudo -u dev bash -lc 'cd ~/app && npm install'" } else { '/bin/true' }

$substitutions = [ordered]@{
    '${NAME}'              = $Name
    '${SSH_PUBKEY}'        = $sshPublicKey
    '${RDP_PASSWORD}'      = $RdpPassword
    '${ADB_SERVER_SOCKET}' = $adbServerSocket
    '${DEVICE_SERIAL}'     = $DeviceSerial
    '${CLONE_CMD}'         = $cloneCmd
    '${INSTALL_CMD}'       = $installCmd
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
    Write-Host "  Screenshot  : adb -s ${ip}:5555 exec-out screencap -p > screen.png"
}
Write-Host "  Metro       : http://${ip}:8081"
Write-Host ''
Write-Note 'First boot is still running git clone and npm install; give it a minute before attaching.'
Write-Note "Log the agent in once in this VM: ssh dev@$ip -t claude   (then /login, subscription account)."
