<#
.SYNOPSIS
    Prints the RDP password of a dev VM created by New-DevVM.ps1.

.DESCRIPTION
    New-DevVM.ps1 shows the generated password exactly once. It is not lost after that: the
    cloud-init seed ISO the VM booted from stays in the project folder for the life of the
    VM, and its user-data carries the password in plain text (a chpasswd entry). This script
    reads it back from there.

    If Set-DevVMPassword.ps1 has changed the password since, the ISO is stale. That script
    records the new value in rdp-password.txt next to the ISO, and this one prefers that
    file when it exists.

    The ISO is scanned as raw bytes rather than mounted. The VM holds it open as a DVD
    drive, mounting on the host needs a drive letter and a dismount even on failure, and
    user-data is a small text file whose bytes sit verbatim inside the image - a scan finds
    the line without any of that.

    No Administrator rights needed: only files under the project folder are read.

.PARAMETER Name
    Project / VM name, e.g. app-foo. The same value passed to New-DevVM.ps1.

.PARAMETER Root
    Where images and VMs live. Defaults to $env:DEVVM_ROOT, else C:\Hyper-V. -VmRoot derives
    from it, and must be the same root New-DevVM.ps1 built the VM under.

.PARAMETER User
    Guest account to look up. Default dev, the only account New-DevVM.ps1 creates.

.OUTPUTS
    The password, as a plain string on the pipeline. Everything else goes to the host
    stream, so piping into Set-Clipboard copies just the password.

.EXAMPLE
    .\Get-DevVMPassword.ps1 -Name app-foo

.EXAMPLE
    .\Get-DevVMPassword.ps1 -Name app-foo | Set-Clipboard
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,30}$')]
    [string]$Name,

    [string]$Root = $(if ($env:DEVVM_ROOT) { $env:DEVVM_ROOT } else { 'C:\Hyper-V' }),

    [string]$VmRoot = [IO.Path]::Combine($Root, 'vms'),

    [ValidatePattern('^[a-z_][a-z0-9_-]*$')]
    [string]$User = 'dev'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Note { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }

$vmPath = Join-Path $VmRoot $Name
if (-not (Test-Path -LiteralPath $vmPath)) {
    throw "No project folder for '$Name' at $vmPath. Check -Name, or -Root if the VMs live on another drive."
}

# Written by Set-DevVMPassword.ps1; newer than anything on the ISO.
$recordPath = Join-Path $vmPath 'rdp-password.txt'
if (Test-Path -LiteralPath $recordPath) {
    $recorded = (Get-Content -LiteralPath $recordPath -Raw).Trim()
    if ($recorded) {
        Write-Note "from $recordPath (set after creation)"
        return $recorded
    }
}

$seedIso = Join-Path $vmPath 'seed.iso'
if (-not (Test-Path -LiteralPath $seedIso)) {
    throw "No seed ISO at $seedIso, so the original password cannot be recovered. Set a new one: .\Set-DevVMPassword.ps1 -Name $Name"
}

# Latin-1 maps every byte to exactly one char, so the ASCII text survives intact.
$bytes = [IO.File]::ReadAllBytes($seedIso)
$text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)

# The chpasswd block New-DevVM.ps1 renders:
#     chpasswd:
#       list: |
#         dev:<password>
$pattern = '(?m)^chpasswd:\r?\n\s+list:\s*\|\r?\n\s+' + [regex]::Escape($User) + ':([^\r\n]+)'
$match = [regex]::Match($text, $pattern)
if (-not $match.Success) {
    throw "No chpasswd entry for '$User' found in $seedIso. Was this VM created by New-DevVM.ps1?"
}

Write-Note "from $seedIso (as set at creation)"
return $match.Groups[1].Value
