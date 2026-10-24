<#
.SYNOPSIS
    Prints the RDP password of a dev VM created by New-AgentVM.ps1.

.DESCRIPTION
    New-AgentVM.ps1 shows the generated password once, and Set-AgentVMPassword.ps1 - which
    sets every password, the first one included - saves it in Windows Credential Manager as
    agent-vm:<Name>. This script reads it back from there, for the current Windows user.

    VMs created before that keep their password elsewhere, and are still read:
      - rdp-password.txt in the project folder, written by an earlier Set-AgentVMPassword.ps1.
      - The cloud-init seed ISO, whose user-data used to carry the original password in a
        chpasswd entry. The ISO is scanned as raw bytes rather than mounted: the VM holds it
        open as a DVD drive, and user-data's bytes sit verbatim inside the image.

    No Administrator rights needed.

.PARAMETER Name
    Project / VM name, e.g. app-foo. The same value passed to New-AgentVM.ps1.

.PARAMETER Root
    Where images and VMs live. Defaults to $env:AGENTVM_ROOT, else C:\Hyper-V. -VmRoot derives
    from it, and must be the same root New-AgentVM.ps1 built the VM under.

.PARAMETER User
    Guest account to look up. Default dev, the only account New-AgentVM.ps1 creates.

.OUTPUTS
    The password, as a plain string on the pipeline. Everything else goes to the host
    stream, so piping into Set-Clipboard copies just the password.

.EXAMPLE
    .\Get-AgentVMPassword.ps1 -Name app-foo

.EXAMPLE
    .\Get-AgentVMPassword.ps1 -Name app-foo | Set-Clipboard
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,30}$')]
    [string]$Name,

    [string]$Root = $(if ($env:AGENTVM_ROOT) { $env:AGENTVM_ROOT } else { 'C:\Hyper-V' }),

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

# Credential Manager first: where Set-AgentVMPassword.ps1 keeps every password it sets. cmdkey
# can only write, so this reads through CredRead. The blob is the password in UTF-16.
Add-Type -Namespace AgentVM -Name Cred -MemberDefinition @'
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CREDENTIAL {
    public int Flags; public int Type; public string TargetName; public string Comment;
    public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
    public int Persist; public int AttributeCount; public IntPtr Attributes;
    public string TargetAlias; public string UserName;
}
[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
[DllImport("advapi32.dll")]
public static extern void CredFree(IntPtr credential);

public static string ReadGenericPassword(string target) {
    IntPtr ptr;
    if (!CredRead(target, 1, 0, out ptr)) { return null; }   // 1 = CRED_TYPE_GENERIC
    try {
        var cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
        if (cred.CredentialBlobSize == 0) { return null; }
        return Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2);
    } finally { CredFree(ptr); }
}
'@

$saved = [AgentVM.Cred]::ReadGenericPassword("agent-vm:$Name")
if ($saved) {
    Write-Note "from Windows Credential Manager (agent-vm:$Name)"
    return $saved
}

# Written by earlier versions of Set-AgentVMPassword.ps1; newer than anything on the ISO.
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
    throw "No password saved for '$Name' in Credential Manager, and no seed ISO at $seedIso. Set a new one: .\Set-AgentVMPassword.ps1 -Name $Name"
}

# Latin-1 maps every byte to exactly one char, so the ASCII text survives intact.
$bytes = [IO.File]::ReadAllBytes($seedIso)
$text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)

# The chpasswd block New-AgentVM.ps1 renders:
#     chpasswd:
#       list: |
#         dev:<password>
$pattern = '(?m)^chpasswd:\r?\n\s+list:\s*\|\r?\n\s+' + [regex]::Escape($User) + ':([^\r\n]+)'
$match = [regex]::Match($text, $pattern)
if (-not $match.Success) {
    throw "No password saved for '$Name' in Credential Manager, and none on its seed ISO. Set a new one: .\Set-AgentVMPassword.ps1 -Name $Name"
}

Write-Note "from $seedIso (as set at creation)"
return $match.Groups[1].Value
