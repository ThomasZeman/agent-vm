<#
.SYNOPSIS
    Removes a per-project React Native development VM created by New-AgentVM.ps1.

.DESCRIPTION
    The companion to New-AgentVM.ps1 (section 8.2 of linux-vm-on-windows.md):

      1. Shuts the VM down - gracefully first, then forced if it does not stop in time.
      2. Removes the VM definition from Hyper-V.
      3. Deletes the project folder: differencing disk, cloud-init seed ISO and VM config.
      4. Deletes the generated .rdp file and the RDP password saved in Credential Manager,
         both under the VM's address and under agent-vm:<Name>.

    Everything in a project VM is disposable: the repo lives on the remote, the toolchain
    lives in the golden image, and a replacement is two minutes away. The one thing that is
    not disposable is the golden VHDX, so the script refuses to touch any disk that is not a
    differencing child living inside the project folder.

    Run from an elevated PowerShell session; the Hyper-V cmdlets require Administrator.

.PARAMETER Name
    Project / VM name, e.g. app-foo. The same value passed to New-AgentVM.ps1.

.PARAMETER Root
    Where images and VMs live. Defaults to $env:AGENTVM_ROOT, else C:\Hyper-V. -VmRoot derives
    from it, and must be the same root New-AgentVM.ps1 built the VM under.

.PARAMETER KeepFiles
    Remove the VM from Hyper-V but leave the project folder and its disk on disk.
    Useful when you want the differencing disk kept for forensics or a later re-import.

.PARAMETER Force
    Skip the confirmation prompt.

.PARAMETER ShutdownTimeoutSeconds
    How long to wait for a graceful guest shutdown before turning the VM off. Default 60.

.EXAMPLE
    .\Remove-AgentVM.ps1 -Name app-foo

.EXAMPLE
    .\Remove-AgentVM.ps1 -Name app-foo -Force
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,30}$')]
    [string]$Name,

    [string]$Root = $(if ($env:AGENTVM_ROOT) { $env:AGENTVM_ROOT } else { 'C:\Hyper-V' }),

    [string]$VmRoot = [IO.Path]::Combine($Root, 'vms'),

    [string]$RdpOutputDirectory = $PWD.Path,

    [switch]$KeepFiles,

    [switch]$Force,

    [int]$ShutdownTimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Force) { $ConfirmPreference = 'None' }

# ---------------------------------------------------------------- helpers ---

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must run from an elevated PowerShell session; the Hyper-V cmdlets require Administrator.'
    }
}

function Test-PathInside {
    param([string]$Candidate, [string]$Container)
    # Compare normalized full paths, so ..\ and trailing slashes cannot escape the container.
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $containerFull = [System.IO.Path]::GetFullPath($Container).TrimEnd('\')
    return $candidateFull.Equals($containerFull, [StringComparison]::OrdinalIgnoreCase) -or
           $candidateFull.StartsWith($containerFull + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-FolderSizeGb {
    param([string]$Path)
    $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
              Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { return 0 }
    [math]::Round($bytes / 1GB, 2)
}

function Stop-AgentVMHard {
    param([string]$VMName, [int]$TimeoutSeconds)

    $vm = Get-VM -Name $VMName
    if ($vm.State -eq 'Off') {
        Write-Note 'already off'
        return
    }

    # Ask the guest first so cloud-init state and the agent's tmux session close cleanly.
    Write-Note "requesting guest shutdown, up to $TimeoutSeconds s"
    try {
        Stop-VM -Name $VMName -Force -ErrorAction Stop
    } catch {
        Write-Note "graceful shutdown was refused: $($_.Exception.Message)"
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Get-VM -Name $VMName).State -eq 'Off') { return }
        Start-Sleep -Seconds 2
    }

    Write-Note 'guest did not stop in time; turning the VM off'
    Stop-VM -Name $VMName -TurnOff -Force
}

# -------------------------------------------------------------- preflight ---

Assert-Administrator

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'The Hyper-V PowerShell module is not available. Enable the Hyper-V feature first (section 2).'
}

$vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
$vmPath = Join-Path $VmRoot $Name
$folderExists = Test-Path -LiteralPath $vmPath
$rdpPath = Join-Path $RdpOutputDirectory "$Name.rdp"
$rdpExists = Test-Path -LiteralPath $rdpPath

if (-not $vm -and -not $folderExists -and -not $rdpExists) {
    Write-Host "Nothing to do: no VM, project folder or .rdp file named '$Name'."
    return
}

if (-not $vm) {
    Write-Note "no VM named '$Name' in Hyper-V; cleaning up leftover files only"
}

# The golden VHDX is shared by every other project VM. Refuse outright if a disk attached to
# this VM is a parent image or lives outside the project folder (section 10).
$diskPaths = @()
if ($vm) {
    $diskPaths = @(Get-VMHardDiskDrive -VMName $Name | Select-Object -ExpandProperty Path)
}

foreach ($diskPath in $diskPaths) {
    if (-not (Test-PathInside -Candidate $diskPath -Container $vmPath)) {
        throw "Refusing to continue: '$Name' uses a disk outside its project folder ($diskPath). Detach it and remove the VM by hand."
    }

    $vhd = Get-VHD -Path $diskPath -ErrorAction SilentlyContinue
    if ($vhd -and -not $vhd.ParentPath) {
        throw "Refusing to continue: '$diskPath' is not a differencing disk, so it may hold data that exists nowhere else. Remove the VM by hand."
    }
}

# A grandchild would be orphaned by deleting this disk.
foreach ($diskPath in $diskPaths) {
    $children = Get-VM | Get-VMHardDiskDrive | Where-Object { $_.VMName -ne $Name } | ForEach-Object {
        $childVhd = Get-VHD -Path $_.Path -ErrorAction SilentlyContinue
        if ($childVhd -and $childVhd.ParentPath -and
            (Test-PathInside -Candidate $childVhd.ParentPath -Container $diskPath)) { $_.VMName }
    }
    if ($children) {
        throw "Refusing to continue: $($children -join ', ') use '$diskPath' as a parent disk. Remove those VMs first."
    }
}

# ----------------------------------------------------------------- report ---

Write-Step "Removing dev VM '$Name'"
if ($vm) {
    Write-Note ("state {0}, {1} GB RAM, {2} vCPU" -f $vm.State, ($vm.MemoryStartup / 1GB), $vm.ProcessorCount)
}
if ($folderExists) {
    $sizeGb = Get-FolderSizeGb -Path $vmPath
    if ($KeepFiles) {
        Write-Note "keeping $vmPath ($sizeGb GB)"
    } else {
        Write-Note "deleting $vmPath ($sizeGb GB: differencing disk, seed ISO, VM config)"
    }
}
if ($rdpExists) { Write-Note "deleting $rdpPath" }

# New-AgentVM.ps1 saved the RDP password as TERMSRV/<address>. The .rdp file names the address
# it was saved under; a running VM reports its current one. Collected now, before the VM
# stops reporting anything.
$rdpAddresses = @()
if ($rdpExists) {
    $rdpAddresses += @(Get-Content -LiteralPath $rdpPath |
        Where-Object { $_ -match '^full address:s:(.+)$' } | ForEach-Object { $Matches[1].Trim() })
}
if ($vm) {
    $rdpAddresses += @((Get-VMNetworkAdapter -VMName $Name).IPAddresses |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^169\.254\.' })
}
$rdpAddresses = @($rdpAddresses | Sort-Object -Unique)
foreach ($address in $rdpAddresses) { Write-Note "deleting saved RDP credentials for $address" }

$target = "$Name (VM" + $(if ($KeepFiles) { '' } else { " and $vmPath" }) + ')'
if (-not $PSCmdlet.ShouldProcess($target, 'Remove dev VM')) {
    Write-Host 'Cancelled.'
    return
}

# ------------------------------------------------------------ stop, remove ---

if ($vm) {
    Write-Step 'Stopping the VM'
    Stop-AgentVMHard -VMName $Name -TimeoutSeconds $ShutdownTimeoutSeconds

    # Checkpoints are disabled on these VMs, but a hand-made one would block disk deletion.
    $snapshots = @(Get-VMSnapshot -VMName $Name -ErrorAction SilentlyContinue)
    if ($snapshots.Count -gt 0) {
        Write-Step "Removing $($snapshots.Count) checkpoint(s)"
        Remove-VMSnapshot -VMName $Name -IncludeAllChildSnapshots -Confirm:$false
        # Merging runs asynchronously; wait for it before touching the files.
        while (@(Get-VM -Name $Name).Status -match 'Merging') { Start-Sleep -Seconds 2 }
    }

    Write-Step 'Removing the VM from Hyper-V'
    Remove-VM -Name $Name -Force
}

if ($folderExists -and -not $KeepFiles) {
    Write-Step 'Deleting the project folder'
    # Hyper-V can hold the VHDX open for a moment after Remove-VM.
    $attempt = 0
    while ($true) {
        try {
            Remove-Item -LiteralPath $vmPath -Recurse -Force -ErrorAction Stop
            break
        } catch {
            $attempt++
            if ($attempt -ge 5) {
                throw "Could not delete ${vmPath}: $($_.Exception.Message)"
            }
            Start-Sleep -Seconds 2
        }
    }
}

if ($rdpExists) {
    Remove-Item -LiteralPath $rdpPath -Force -ErrorAction SilentlyContinue
}

# DHCP may hand the address to the next VM; a stale entry would log in with this one's password.
foreach ($address in $rdpAddresses) {
    & cmdkey.exe "/delete:TERMSRV/$address" | Out-Null
}
# Where Set-AgentVMPassword.ps1 keeps the password for Get-AgentVMPassword.ps1.
& cmdkey.exe "/delete:agent-vm:$Name" | Out-Null

Write-Host ''
Write-Step "'$Name' removed"
if ($KeepFiles -and $folderExists) {
    Write-Note "project files kept at $vmPath"
}
Write-Note "Recreate it with: .\New-AgentVM.ps1 -Name $Name -Repo <git-url>"
