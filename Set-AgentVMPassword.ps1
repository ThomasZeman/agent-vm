<#
.SYNOPSIS
    Sets the RDP password of a running dev VM created by New-AgentVM.ps1.

.DESCRIPTION
    New-AgentVM.ps1 calls this for the first password of every VM, and it is the way to
    change it later. Everything goes over SSH, which needs no password of its own:
    New-AgentVM.ps1 put your public key on the dev account, and dev has passwordless sudo.

    In the guest it sets the Unix password (chpasswd) and the agent desktop's VNC password,
    and starts the agent desktop if it is not running yet - on a new VM it cannot start
    before it has a password. On the host it saves the password in Windows Credential
    Manager twice: as TERMSRV/<address>, which the .rdp file logs in with, and as
    agent-vm:<Name>, which Get-AgentVMPassword.ps1 reads back.

    The password is never written to a file. It is not on the seed ISO either, which stays
    attached to the VM and is readable from inside it. The new value reaches the guest on
    stdin, never on a command line, so it shows up in neither the host's nor the guest's
    process list.

    Administrator is only needed when the VM's address has to be looked up through Hyper-V.
    Pass -IpAddress to skip the lookup and run unelevated.

.PARAMETER Name
    Project / VM name, e.g. app-foo. The same value passed to New-AgentVM.ps1.

.PARAMETER Password
    The new password. Generated when omitted (8 unambiguous alphanumerics, like New-AgentVM.ps1)
    and printed at the end. 1 to 8 letters, digits or !#%+,./:=?@^_~-. At most 8 because
    VNC, which guards the agent desktop, ignores everything after the 8th character; no
    spaces or quotes because cmdkey receives it on its command line.

.PARAMETER IpAddress
    Guest address. Looked up from the VM's network adapter when omitted, which requires an
    elevated session.

.PARAMETER Root
    Where images and VMs live. Defaults to $env:AGENTVM_ROOT, else C:\Hyper-V. -VmRoot derives
    from it, and must be the same root New-AgentVM.ps1 built the VM under.

.PARAMETER User
    Guest account to change. Default dev.

.PARAMETER NoRecord
    Change the password in the guest only, and leave Credential Manager alone. The .rdp file
    and Get-AgentVMPassword.ps1 then still have the previous password.

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
    # At most 8: VNC authentication ignores the rest, so a longer password would only look
    # stronger. cmdkey takes it as a command-line argument, so a space or a quote would be
    # split or mangled on its way into Credential Manager.
    [ValidatePattern('^[A-Za-z0-9!#%+,./:=?@^_~-]{1,8}$')]
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
# PowerShell appends to piped text, and sed a UTF-8 byte order mark in front of it: Windows
# PowerShell writes one whenever the console's input encoding is UTF-8 with a BOM (chcp
# 65001, or a profile that sets [Console]::InputEncoding), and chpasswd then rejects user
# "<BOM>dev" with "Authentication token manipulation error". New-AgentVM.ps1's hand-off
# strips both in the guest for the same reason.
"${User}:${Password}" | & ssh @sshOpts $target "sed '1s/^\xEF\xBB\xBF//' | tr -d '\r' | sudo chpasswd"
if ($LASTEXITCODE -ne 0) {
    throw "ssh exited $LASTEXITCODE; the password was NOT changed. Is the VM up and your key in ~/.ssh/authorized_keys of ${User}? A stale known_hosts entry for $IpAddress (ssh-keygen -R $IpAddress) also causes this."
}

# The agent desktop checks its own VNC password, not the Unix one (10-desktop-xrdp.sh).
#
# On a new VM there is no ~/.vnc/passwd yet, so the unit's ConditionPathExists skipped it at
# boot; it is started here, once it has a password. On a running desktop, Xvnc reads a copy
# that tigervncsession made under /tmp at startup, but re-reads it on every connection, so
# overwriting both files switches the password without restarting the desktop - and the
# agent running in it. Images without the agent desktop exit 0 early.
$vncUpdate = @'
[ -d ~/.vnc ] && command -v vncpasswd >/dev/null || exit 0
umask 077
sed '1s/^\xEF\xBB\xBF//' | tr -d '\r' | vncpasswd -f > ~/.vnc/passwd.new && mv ~/.vnc/passwd.new ~/.vnc/passwd || exit 1
if ! systemctl is-active --quiet tigervncserver@:1; then
    sudo systemctl start tigervncserver@:1
    exit
fi
pid=$(pgrep -x -u $(id -u) Xtigervnc) || exit 0
live=$(tr '\0' '\n' < /proc/$pid/cmdline | grep -A1 -- -PasswordFile | tail -1)
case $live in /*) cp ~/.vnc/passwd $live ;; esac
'@
$Password | & ssh @sshOpts $target ($vncUpdate -replace "`r`n", "`n")
if ($LASTEXITCODE -ne 0) {
    Write-Warning "The Unix password changed, but the agent desktop's VNC password did not (ssh exited $LASTEXITCODE). RDP to the agent desktop still takes the old one."
}

# Credential Manager is the only place the password is kept on the host; it is encrypted
# for the current Windows user. TERMSRV/<address> is what mstsc looks up when the .rdp file
# connects. agent-vm:<Name> survives a DHCP address change and is what Get-AgentVMPassword.ps1
# reads, since cmdkey itself can only write.
if (-not $NoRecord) {
    foreach ($credTarget in "TERMSRV/$IpAddress", "agent-vm:$Name") {
        & cmdkey.exe "/generic:$credTarget" "/user:$User" "/pass:$Password" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Note "saved in Credential Manager as $credTarget"
        } else {
            Write-Warning "cmdkey failed for $credTarget ($LASTEXITCODE)."
        }
    }

    # Written by earlier versions of this script. Stale now, and plain text.
    $legacyRecord = Join-Path $vmPath 'rdp-password.txt'
    if (Test-Path -LiteralPath $legacyRecord) {
        Remove-Item -LiteralPath $legacyRecord -Force
        Write-Note "deleted the old plain-text record $legacyRecord"
    }
}

Write-Host ''
Write-Step 'Password changed'
Write-Host "  RDP user : $User"
Write-Host "  RDP pass : $Password"
if ($generated) { Write-Note "generated; read it back any time with .\Get-AgentVMPassword.ps1 -Name $Name" }
