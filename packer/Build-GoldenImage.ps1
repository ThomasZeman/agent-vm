<#
.SYNOPSIS
    Builds the golden VHDX for React Native dev VMs (section 8.1 of linux-vm-on-windows.md).

.DESCRIPTION
    Wraps the Packer build and the post-build steps that are easy to get wrong:

      1. packer init / packer build against ubuntu-rn.pkr.hcl.
      2. Lifts the VHDX out of Packer's exported VM folder to the flat path that
         New-DevVM.ps1 expects (<root>\golden\golden-ubuntu-rn.vhdx).
      3. Compacts it with Optimize-VHD - worth several GB after 90-cleanup.sh's fstrim.
      4. Marks it read-only, because every project VM reads it as a differencing parent.

    Refuses to replace a golden image that still has children (section 10): differencing
    disks depend on the parent byte for byte, so a rebuild must go to a new filename and
    the old file has to stay until its last child is gone.

    Run from an elevated PowerShell session; the Hyper-V builder requires Administrator.

.PARAMETER Root
    Where images and VMs live. Defaults to $env:DEVVM_ROOT, else C:\Hyper-V. -GoldenPath and
    -BuildDirectory derive from it; New-DevVM.ps1 resolves its own defaults the same way, so
    setting DEVVM_ROOT once keeps every script pointed at the same drive.

.PARAMETER GoldenPath
    Where the finished image lands. Match New-DevVM.ps1's -GoldenVhdx.

.PARAMETER OscdimgPath
    oscdimg.exe from the Windows ADK. Packer needs an ISO tool on PATH to build the cidata
    seed; if you already have xorriso or mkisofs on PATH, this is ignored.

.PARAMETER VmName
    Name of the temporary build VM. Must match nothing else in Hyper-V; Packer refuses to
    reuse a name rather than touch a machine it did not create.

.PARAMETER Replace
    Overwrite an existing image at -GoldenPath. Only allowed when it has no children.

.PARAMETER Force
    Delete a leftover build VM without asking. For unattended runs; interactively you get
    the prompt instead.

.PARAMETER SkipBuild
    Skip Packer and just do the move / compact / protect steps on an existing build output.
    Useful when the build succeeded but a post-step failed.

.PARAMETER KeyInterval
    Delay between individual simulated keystrokes (PACKER_KEY_INTERVAL). Hyper-V's synthetic
    keyboard drops characters at Packer's default speed, and one dropped character in
    "autoinstall" drops you into the interactive installer - see the note below Write-Step
    'packer build'. Raise it if that keeps happening.

.NOTES
    The install is UNATTENDED. Nothing in this script or the Packer template types answers
    into Ubuntu's installer, and nothing needs to: http/user-data.pkrtpl.hcl answers every
    question ahead of time, and rides into the VM on a CD labelled "cidata" that cloud-init
    picks up automatically.

    So if the VM console shows the installer asking for a language, a keyboard layout, a disk
    layout or a username, the build has already failed - autoinstall never engaged, and Packer
    is waiting for an SSH login that will never come. Do not answer the questions by hand: the
    machine you would get is not a golden image. Kill the build and see "The installer is
    asking me questions" in README.md.

.EXAMPLE
    .\Build-GoldenImage.ps1

.EXAMPLE
    # Rebuild for an SDK upgrade, side by side with the image in use.
    .\Build-GoldenImage.ps1 -GoldenPath C:\Hyper-V\golden\golden-ubuntu-rn-2026-09.vhdx

.EXAMPLE
    # Keep everything on a second drive; New-DevVM.ps1 -Root E:\Hyper-V then matches.
    .\Build-GoldenImage.ps1 -Root E:\Hyper-V
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PackerDirectory = $PSScriptRoot,

    [string]$Root = $(if ($env:DEVVM_ROOT) { $env:DEVVM_ROOT } else { 'C:\Hyper-V' }),

    [string]$GoldenPath = [IO.Path]::Combine($Root, 'golden', 'golden-ubuntu-rn.vhdx'),

    [string]$BuildDirectory = [IO.Path]::Combine($Root, 'golden', 'build'),

    # Packer builds the cidata seed ISO itself, but only if it finds an ISO tool on PATH.
    # The ADK does not add oscdimg to PATH, so point at it and we prepend it for the build.
    [string]$OscdimgPath = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe',

    [string]$SwitchName = 'DevSwitch',

    # Must match the vm_name default in ubuntu-rn.pkr.hcl; passed through as a -var so the
    # name this script cleans up is the name Packer builds.
    [string]$VmName = 'golden-ubuntu-rn',

    [switch]$Replace,

    [switch]$Force,

    [switch]$SkipBuild,

    # Per-keystroke delay for the GRUB boot command. Packer reads this from the environment
    # only; there is no template setting for it.
    [string]$KeyInterval = '100ms',

    # Which Ubuntu series to build. The exact point release is resolved at build time, so
    # this stays correct as 24.04.x advances - see Resolve-UbuntuIso.
    [string]$UbuntuSeries = '24.04',

    # Escape hatch: build a specific ISO instead of the current point release. Pass
    # -IsoChecksum with it, or the template's default (the live SHA256SUMS) is used, which
    # only works while that ISO is still the current one.
    [string]$IsoUrl,

    [string]$IsoChecksum
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }

function Resolve-UbuntuIso {
    <#
        Returns the CURRENT point release of a series, with its checksum, by reading the
        published SHA256SUMS and taking the highest version in it.

        This exists because pinning an ISO by filename is a time bomb. releases.ubuntu.com
        keeps only the newest point release or two, so a hard-coded
        "ubuntu-24.04.3-live-server-amd64.iso" stops resolving the moment 24.04.5 ships -
        and because iso_checksum reads the live SHA256SUMS, the checksum line disappears in
        the same instant. The build then dies at the download with an error that says
        nothing about a stale pin, months after anyone touched the file.

        Resolving both from one fetch also keeps them consistent by construction: the
        checksum returned here is the checksum OF the URL returned here, which a separate
        iso_url / iso_checksum pair cannot guarantee.

        Deliberately takes the newest: this image is meant to ship current everything.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Series)

    $sumsUrl = "https://releases.ubuntu.com/$Series/SHA256SUMS"

    $previous = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        $sums = Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing -TimeoutSec 30
    }
    catch {
        throw "Could not fetch $sumsUrl to resolve the Ubuntu ISO: $($_.Exception.Message)"
    }
    finally {
        $ProgressPreference = $previous
    }

    # releases.ubuntu.com serves SHA256SUMS with NO Content-Type header, so Windows
    # PowerShell 5.1 cannot decide it is text and hands back a System.Byte[]. Splitting that
    # on newlines silently yields one useless string of decimal byte values - the regex below
    # then matches nothing and the function reports "no ISO found in SHA256SUMS", which reads
    # exactly like a wrong series or a bad URL. Decode explicitly rather than trusting the
    # header to be there.
    $content = $sums.Content
    if ($content -is [byte[]]) {
        $content = [Text.Encoding]::UTF8.GetString($content)
    }

    # e.g. "e907d92... *ubuntu-24.04.4-live-server-amd64.iso". The version group tolerates a
    # series with no point release (the .0 of a series is published as plain "24.04").
    $pattern = '^(?<sha>[0-9a-fA-F]{64})\s+\*?(?<file>ubuntu-(?<ver>' +
               [regex]::Escape($Series) + '(?:\.\d+)?)-live-server-amd64\.iso)$'

    $candidates = @()
    foreach ($line in ($content -split "`r?`n")) {
        $match = [regex]::Match($line.Trim(), $pattern)
        if ($match.Success) {
            $candidates += [pscustomobject]@{
                Version = [version]$match.Groups['ver'].Value
                File    = $match.Groups['file'].Value
                Sha256  = $match.Groups['sha'].Value.ToLowerInvariant()
            }
        }
    }

    if ($candidates.Count -eq 0) {
        throw "No ubuntu-$Series[.x]-live-server-amd64.iso found in $sumsUrl. Check that '$Series' is a released series."
    }

    $latest = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    [pscustomobject]@{
        Url      = "https://releases.ubuntu.com/$Series/$($latest.File)"
        Checksum = "sha256:$($latest.Sha256)"
        File     = $latest.File
    }
}

function Stop-StaleVm {
    <#
        Turn a leftover build VM off, including from the states Stop-VM itself refuses.

        Killing Packer mid-install regularly leaves the VM wedged in a transitional state -
        "Shutting Down" is the common one, when an ACPI shutdown reached a guest that is still
        in the installer and has nobody to handle it. Hyper-V rejects every state change while
        a transition is in flight, so even Stop-VM -TurnOff -Force fails with "failed to change
        state / the operation cannot be performed while the object is in its current state",
        and the VM can sit there indefinitely.

        So: give the transition a chance to finish, try the polite route, and fall back to
        killing the VM's worker process. Each running VM has its own vmwp.exe holding its
        state, identified by the VM's GUID on its command line; killing that one is the
        equivalent of pulling the plug on that machine alone.
    #>
    param(
        [Parameter(Mandatory)] $Vm,
        [int]$SettleSeconds = 60
    )

    $id = $Vm.Id.Guid
    $settled = @('Off', 'Running', 'Paused', 'Saved')

    # A transition may simply be slow. Wait before forcing anything.
    $deadline = (Get-Date).AddSeconds($SettleSeconds)
    while ((Get-VM -Id $id).State -notin $settled -and (Get-Date) -lt $deadline) {
        Write-Note "waiting for '$($Vm.Name)' to leave the '$((Get-VM -Id $id).State)' state..."
        Start-Sleep -Seconds 5
    }

    if ((Get-VM -Id $id).State -eq 'Off') { return }

    try {
        Stop-VM -Id $id -TurnOff -Force -ErrorAction Stop
    }
    catch {
        Write-Note "Stop-VM refused it ($($_.Exception.Message.Trim())); killing the worker process instead."

        $worker = Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" |
                  Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($id) }
        if (-not $worker) {
            throw "'$($Vm.Name)' is stuck in state '$((Get-VM -Id $id).State)' and has no vmwp.exe worker to kill. Reboot the host, or stop it from Hyper-V Manager."
        }
        $worker | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

        # The state does not flip the instant the process dies.
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-VM -Id $id).State -ne 'Off' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    }

    $final = (Get-VM -Id $id).State
    if ($final -ne 'Off') {
        throw "Could not turn '$($Vm.Name)' off; it is still '$final'. Stop it from Hyper-V Manager, or reboot the host."
    }
}

# -------------------------------------------------------------- preflight ---

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run from an elevated PowerShell session; the Hyper-V builder requires Administrator.'
}

if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
    throw 'packer was not found on PATH. Install it with: winget install HashiCorp.Packer'
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch '$SwitchName' does not exist. Create an external switch bound to your NIC first (section 2)."
}

# The autoinstall seed is a CD Packer builds at run time; without an ISO tool it silently
# builds nothing, the installer finds no cloud-init datasource, and the VM sits on the
# language menu until ssh_timeout expires 60 minutes later.
$isoTool = @('xorriso', 'mkisofs', 'oscdimg') |
           Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
           Select-Object -First 1
if (-not $isoTool) {
    if (Test-Path -LiteralPath $OscdimgPath) {
        $env:PATH = "$(Split-Path -Parent $OscdimgPath);$env:PATH"
        Write-Note "added oscdimg to PATH for this build: $OscdimgPath"
    }
    else {
        throw "No ISO tool on PATH and oscdimg not found at $OscdimgPath. Install the Windows ADK (winget install Microsoft.WindowsADK, Deployment Tools feature) or pass -OscdimgPath."
    }
}

$template = Join-Path $PackerDirectory 'ubuntu-rn.pkr.hcl'
if (-not (Test-Path -LiteralPath $template)) {
    throw "Packer template not found: $template"
}

$sshPublicKey = Join-Path $HOME '.ssh\id_ed25519.pub'
if (-not (Test-Path -LiteralPath $sshPublicKey)) {
    throw "No SSH public key at $sshPublicKey. Create one with: ssh-keygen -t ed25519"
}

# Nested virtualization is not optional: 40-emulator-snapshot.sh boots the AVD inside the
# build VM. Fail here rather than 40 minutes in.
$hostCpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if (-not $hostCpu.VirtualizationFirmwareEnabled -and -not $hostCpu.SecondLevelAddressTranslationExtensions) {
    Write-Warning 'Could not confirm hardware virtualization support; if the build fails at the emulator step, check BIOS settings.'
}

# Replacing an image that still backs live VMs would corrupt every one of them.
if ((Test-Path -LiteralPath $GoldenPath) -and -not $SkipBuild) {
    if (-not $Replace) {
        throw "$GoldenPath already exists. Build to a new filename for an upgrade, or pass -Replace if it is unused."
    }

    $children = Get-VM | Get-VMHardDiskDrive | ForEach-Object {
        $vhd = Get-VHD -Path $_.Path -ErrorAction SilentlyContinue
        if ($vhd -and $vhd.ParentPath -and
            $vhd.ParentPath.Equals($GoldenPath, [StringComparison]::OrdinalIgnoreCase)) { $_.VMName }
    }
    if ($children) {
        throw "Refusing to replace ${GoldenPath}: $($children -join ', ') use it as a differencing parent. Build to a new filename instead."
    }
}

# ------------------------------------------------------------------ build ---

if (-not $SkipBuild) {
    # An interrupted run (Ctrl+C at the installer, a failed provisioner) leaves the build VM
    # registered, and Packer will not reuse the name - it has no way to tell its own leftovers
    # from a machine you care about. Ask, rather than fail with "set your vm_name to a unique
    # value", which is the wrong advice when the collision is with the last attempt.
    # This has to happen before the build directory goes: a running VM holds its VHDX open.
    $stale = Get-VM -Name $VmName -ErrorAction SilentlyContinue
    if ($stale) {
        $staleDisks = @(Get-VMHardDiskDrive -VM $stale | Select-Object -ExpandProperty Path)
        $caption = "A VM named '$VmName' already exists (state: $($stale.State)) - almost certainly the leftover of an earlier build."
        $query = 'Delete it and start a fresh build?'
        if (-not ($Force -or $PSCmdlet.ShouldContinue($query, $caption))) {
            throw "Kept the existing VM '$VmName'. Delete it in Hyper-V Manager, or build under another name with -VmName."
        }

        Write-Step "Deleting the leftover VM '$VmName'"
        Stop-StaleVm -Vm $stale
        Remove-VM -VM $stale -Force
        foreach ($disk in $staleDisks) {
            if (-not (Test-Path -LiteralPath $disk)) { continue }
            # Only scratch under the build directory is ours to delete.
            if ($disk.StartsWith($BuildDirectory, [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $disk -Force
            }
            else {
                Write-Warning "Left $disk in place: it is outside $BuildDirectory. Delete it yourself if it was build scratch."
            }
        }
    }

    if (Test-Path -LiteralPath $BuildDirectory) {
        if (-not $PSCmdlet.ShouldProcess($BuildDirectory, 'Delete previous Packer output')) { return }
        Write-Step "Clearing previous build output"
        Remove-Item -LiteralPath $BuildDirectory -Recurse -Force
    }

    # Resolve the ISO before anything expensive happens: a wrong series or an unreachable
    # releases.ubuntu.com should fail here, in a second, not 20 minutes into a build.
    if ($IsoUrl) {
        $isoArgs = @('-var', "iso_url=$IsoUrl")
        if ($IsoChecksum) { $isoArgs += @('-var', "iso_checksum=$IsoChecksum") }
        Write-Step 'Ubuntu ISO (explicit)'
        Write-Note $IsoUrl
    }
    else {
        Write-Step "Resolving the current Ubuntu $UbuntuSeries ISO"
        $iso = Resolve-UbuntuIso -Series $UbuntuSeries
        $isoArgs = @('-var', "iso_url=$($iso.Url)", '-var', "iso_checksum=$($iso.Checksum)")
        Write-Note "$($iso.File) - $($iso.Checksum)"
    }

    Write-Step 'packer init'
    & packer init $PackerDirectory
    if ($LASTEXITCODE -ne 0) { throw "packer init failed with exit code $LASTEXITCODE" }

    # Cheap, and it catches the expensive mistake: the template runs yamldecode() over the
    # rendered autoinstall config, so a YAML error there fails here in a second instead of
    # 20 minutes in, on an installer prompt nobody is going to answer.
    Write-Step 'packer validate'
    & packer validate `
        @isoArgs `
        -var "output_directory=$($BuildDirectory -replace '\\', '/')" `
        -var "switch_name=$SwitchName" `
        -var "vm_name=$VmName" `
        $PackerDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "packer validate failed with exit code $LASTEXITCODE. If it names yamldecode, http/user-data.pkrtpl.hcl is not valid YAML - see README.md, 'The installer is asking me questions'."
    }

    Write-Step 'packer build (expect 30-50 minutes)'
    Write-Note 'Most of it is the Android system image download and the emulator first boot.'
    Write-Host ''
    Write-Host '    The Ubuntu install is unattended - nothing here answers installer prompts.' -ForegroundColor Yellow
    Write-Host '    Expected: "Waiting for SSH..." while the console shows a scrolling install log.' -ForegroundColor Yellow
    Write-Host '    Broken:   the console shows the installer asking for a language / keyboard /' -ForegroundColor Yellow
    Write-Host '              disk layout / username. That means autoinstall never engaged.' -ForegroundColor Yellow
    Write-Host '              Do not answer them. Diagnose from the VM console BEFORE Ctrl+C' -ForegroundColor Yellow
    Write-Host '              (Packer deletes the VM on the way out): README.md, "The installer' -ForegroundColor Yellow
    Write-Host '              is asking me questions".' -ForegroundColor Yellow
    Write-Host ''

    # Hyper-V's synthetic keyboard drops characters when Packer types the GRUB command at full
    # speed; a mangled "autoinstall" is exactly the failure described above. Packer takes this
    # from the environment only, so it cannot live in the template next to the boot command.
    $env:PACKER_KEY_INTERVAL = $KeyInterval
    Write-Note "PACKER_KEY_INTERVAL=$KeyInterval (raise it if the boot command keeps mistyping)"

    $started = Get-Date
    & packer build `
        @isoArgs `
        -var "output_directory=$($BuildDirectory -replace '\\', '/')" `
        -var "switch_name=$SwitchName" `
        -var "vm_name=$VmName" `
        $PackerDirectory
    if ($LASTEXITCODE -ne 0) {
        $elapsed = (Get-Date) - $started
        # The build fails at one of two very different stages, and the fix differs completely,
        # so point at both instead of assuming one. Read the LAST guest line in the output
        # above (or log.txt) to tell them apart:
        #   * "Timeout waiting for SSH" / no "Provisioning with shell script" line -> the boot
        #     command missed and the VM sat on the interactive installer; autoinstall never
        #     engaged. Retry with a larger -KeyInterval (see README, "The installer is asking
        #     me questions").
        #   * A provisioner ran and a guest command errored (e.g. an apt or `tee` failure) ->
        #     autoinstall and SSH worked; the fix is in the failing scripts\*.sh, not here.
        throw @"
packer build failed with exit code $LASTEXITCODE after $("{0:hh\:mm\:ss}" -f $elapsed).

Read the LAST '==> hyperv-iso.ubuntu:' line above (or in log.txt) to see which stage failed:

  * If it says 'Timeout waiting for SSH' and no 'Provisioning with shell script' line ever
    appeared, the autoinstall never engaged and the VM sat on the interactive installer.
    Retry with a larger -KeyInterval (currently $KeyInterval); see README.md, "The installer
    is asking me questions".

  * If a provisioner was running and a guest command failed (an apt error, a missing package,
    a failing 'tee', a non-zero exit N), then autoinstall and SSH worked fine - the fix is in
    the failing scripts\*.sh, not in the boot command or -KeyInterval.
"@
    }
    Write-Note ("build took {0:hh\:mm\:ss}" -f ((Get-Date) - $started))
}

# ----------------------------------------------------- place, compact, lock ---

Write-Step 'Locating the built VHDX'
# Packer exports a whole VM; the disk is one level down under "Virtual Hard Disks".
$built = Get-ChildItem -LiteralPath $BuildDirectory -Filter '*.vhdx' -Recurse -File |
         Sort-Object Length -Descending |
         Select-Object -First 1
if (-not $built) {
    throw "No .vhdx found under $BuildDirectory. Did the build complete?"
}
Write-Note "$($built.FullName) ($([math]::Round($built.Length / 1GB, 2)) GB)"

$goldenDir = Split-Path -Parent $GoldenPath
if (-not (Test-Path -LiteralPath $goldenDir)) {
    New-Item -ItemType Directory -Path $goldenDir -Force | Out-Null
}

if (Test-Path -LiteralPath $GoldenPath) {
    if (-not $PSCmdlet.ShouldProcess($GoldenPath, 'Replace existing golden image')) { return }
    Set-ItemProperty -LiteralPath $GoldenPath -Name IsReadOnly -Value $false
    Remove-Item -LiteralPath $GoldenPath -Force
}

Write-Step "Moving the image to $GoldenPath"
Move-Item -LiteralPath $built.FullName -Destination $GoldenPath

Write-Step 'Compacting'
Set-ItemProperty -LiteralPath $GoldenPath -Name IsReadOnly -Value $false
Optimize-VHD -Path $GoldenPath -Mode Full
$final = Get-Item -LiteralPath $GoldenPath
Write-Note "$([math]::Round($final.Length / 1GB, 2)) GB after compaction"

Write-Step 'Marking read-only'
# Cheap insurance for the rule in section 10: children read this file directly, so an
# accidental attach-and-boot would corrupt every VM at once.
Set-ItemProperty -LiteralPath $GoldenPath -Name IsReadOnly -Value $true

Write-Step 'Cleaning up the Packer export'
Remove-Item -LiteralPath $BuildDirectory -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Step 'Golden image ready'
Write-Note $GoldenPath
Write-Note "Create the first VM with: .\New-DevVM.ps1 -Name app-foo -Repo <git-url> -GoldenVhdx `"$GoldenPath`""
