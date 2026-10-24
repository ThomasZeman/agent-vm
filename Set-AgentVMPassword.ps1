<#
.SYNOPSIS
    Sets a new RDP password on a running dev VM created by New-AgentVM.ps1.

.DESCRIPTION
    Changes the guest password over SSH, which needs no password of its own: New-AgentVM.ps1
    put your public key on the dev account, and dev has passwordless sudo.

    The new value reaches the guest on stdin, never on a command line, so it shows up in
    neither the host's nor the guest's process list. Carriage returns are stripped on the
    guest side because PowerShell terminates piped text with CRLF and chpasswd would keep
    the \r as part of the password.

    The seed ISO in the project folder still holds the original password, but cloud-init
    applies chpasswd only on the first boot of an instance, so the change is permanent. The
    new value is recorded in rdp-password.txt next to the ISO, where Get-AgentVMPassword.ps1
    looks first. That file is no more exposed than the ISO beside it, which already carries
    the original in plain text.

    Administrator is only needed when the VM's address has to be looked up through Hyper-V.
    Pass -IpAddress to skip the lookup and run unelevated.

.PARAMETER Name
    Project / VM name, e.g. app-foo. The same value passed to New-AgentVM.ps1.

.PARAMETER Password
    The new password. Generated when omitted (8 unambiguous alphanumerics, like New-AgentVM.ps1)
    and printed at the end. Printable ASCII only, 1 to 64 characters.

.PARAMETER IpAddress
    Guest address. Looked up from the VM's network adapter when omitted, which requires an
    elevated session.

.PARAMETER Root
    Where images and VMs live. Defaults to $env:AGENTVM_ROOT, else C:\Hyper-V. -VmRoot derives
    from it, and must be the same root New-AgentVM.ps1 built the VM under.

.PARAMETER User
    Guest account to change. Default dev.

.PARAMETER NoRecord
    Do not write rdp-password.txt. Get-AgentVMPassword.ps1 will then keep reporting the
    original password from the seed ISO.

.EXAMPLE
    .\Set-AgentVMPassword.ps1 -Name app-foo
    Generates a password, applies it and prints it.

.EXAMPLE
    .\Set-AgentVMPassword.ps1 -Name app-foo -Password hunter2 -IpAddress 192.168.1.42
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,30}$')]
    [string]$Name,

    # Printable ASCII. chpasswd splits on the first colon, so a colon inside is fine.
    [ValidatePattern('^[\x20-\x7E]{1,64}$')]
    [string]$Password,

    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}$')]
    [string]$IpAddress,

    [string]$Root = $(if ($env:AGENTVM_ROOT) { $env:AGENTVM_ROOT } else { 'C:\Hyper-V' }),

    [string]$VmRoot = [IO.Path]::Combine($Root, 'vms'),

    [ValidatePattern('^[a-z_][a-z0-9_-]*$')]
    [string]$User = 'dev',

    [switch]$NoRecord
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- helpers ---

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }

function New-RandomPassword {
    param([int]$Length = 8)
    # Same alphabet as New-AgentVM.ps1: no 0/O, 1/l/I, so it can be read off a screen.
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
        throw 'Looking up the VM address needs an elevated PowerShell session (Hyper-V cmdlets). Elevate, or pass -IpAddress.'
    }
}

function Get-GuestIPv4 {
    param([string]$VMName)

    $addresses = @((Get-VMNetworkAdapter -VMName $VMName).IPAddresses)
    foreach ($address in $addresses) {
        if ($address -match '^\d{1,3}(\.\d{1,3}){3}$' -and $address -notmatch '^169\.254\.') {
            return $address
        }
    }
    return $null
}

# -------------------------------------------------------------- preflight ---

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    throw 'ssh is not on PATH. Add the Windows OpenSSH client (Settings > Optional features).'
}

$vmPath = Join-Path $VmRoot $Name
if (-not (Test-Path -LiteralPath $vmPath)) {
    throw "No project folder for '$Name' at $vmPath. Check -Name, or -Root if the VMs live on another drive."
}

if (-not $IpAddress) {
    Assert-Administrator
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        throw 'The Hyper-V PowerShell module is not available. Pass -IpAddress instead.'
    }
    $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
    if (-not $vm) { throw "No VM named '$Name' in Hyper-V." }
    if ($vm.State -ne 'Running') {
        throw "'$Name' is $($vm.State). Start it first: Start-VM -Name $Name"
    }
    $IpAddress = Get-GuestIPv4 -VMName $Name
    if (-not $IpAddress) {
        throw "'$Name' has not reported an address yet. Wait for it to boot, or pass -IpAddress."
    }
}

$generated = -not $Password
if ($generated) { $Password = New-RandomPassword }

# --------------------------------------------------------------- change it ---

Write-Step "Setting the password for $User on '$Name' ($IpAddress)"

$target  = "${User}@${IpAddress}"
$sshOpts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10', '-o', 'BatchMode=yes')

# stdin, not argv: keeps the password out of both process lists. tr strips the CRLF that
# PowerShell appends to piped text.
"${User}:${Password}" | & ssh @sshOpts $target "tr -d '\r' | sudo chpasswd"
if ($LASTEXITCODE -ne 0) {
    throw "ssh exited $LASTEXITCODE; the password was NOT changed. Is the VM up and your key in ~/.ssh/authorized_keys of ${User}? A stale known_hosts entry for $IpAddress (ssh-keygen -R $IpAddress) also causes this."
}

if (-not $NoRecord) {
    $recordPath = Join-Path $vmPath 'rdp-password.txt'
    Set-Content -LiteralPath $recordPath -Value $Password -Encoding ASCII -NoNewline
    Write-Note "recorded in $recordPath for Get-AgentVMPassword.ps1"
}

Write-Host ''
Write-Step 'Password changed'
Write-Host "  RDP user : $User"
Write-Host "  RDP pass : $Password"
if ($generated) { Write-Note "generated; read it back any time with .\Get-AgentVMPassword.ps1 -Name $Name" }
