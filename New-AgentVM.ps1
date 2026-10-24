<#
.SYNOPSIS
    Creates a per-project React Native development VM on Hyper-V from the golden Ubuntu image.

.DESCRIPTION
    How it works: DESIGN.md, section 5.

      1. Creates a differencing disk against the immutable golden VHDX (thin clone, seconds).
      2. Creates a Generation 2 VM with nested virtualization enabled, static memory,
         Secure Boot off and checkpoints disabled - all required for KVM inside the guest.
      3. Renders the cloud-init NoCloud seed (user-data / meta-data), builds seed.iso with
         oscdimg and attaches it as a DVD drive.
      4. Starts the VM, waits for a DHCP address and writes a tuned .rdp file.
      5. Once SSH answers and first boot has finished, sets the RDP password through
         Set-AgentVMPassword.ps1: the Unix and VNC passwords in the guest, which starts the
         agent desktop (packer/scripts/10-desktop-xrdp.sh), and Windows Credential Manager
         on the host, so the .rdp file opens straight onto that desktop with no prompt.
      6. Offers to hand this host's logins to the guest over SSH: the GitHub token `gh`
         holds here plus your global git identity, and a long-lived Claude subscription
         token from `claude setup-token`. Each is a separate yes/no, asked before the VM is
         built so the wait is uninterrupted, and each has a -Skip switch.
      7. With -Repo, clones the project into /home/dev/app. Unattended if the GitHub token
         was handed over, otherwise through an interactive `gh auth login` in the guest.

    Steps 5 to 7 are deliberately NOT part of first boot. cloud-init runs before anyone can
    type a password, so anything it needed would have to ship in the image or on the seed
    ISO - and that ISO stays attached to the VM for its whole life and is readable from
    inside the guest. Delivering the password and credentials over SSH afterwards means they
    exist in exactly two places, this host and that one guest, and the golden image stays
    free of any password, GitHub, git or Claude identity at all.

    Run from an elevated PowerShell session; the Hyper-V cmdlets require Administrator.

.PARAMETER Name
    Project / VM name, e.g. app-foo. Used as the hostname, the folder under -VmRoot and the
    .rdp file name.

.PARAMETER Repo
    Project to check out into /home/dev/app, AFTER boot, over SSH. Accepts anything
    `gh repo clone` takes - "owner/repo" or a GitHub URL - and falls back to plain
    `git clone` for a non-GitHub URL. Omit to create a VM with an empty ~/app.

.PARAMETER SkipGitHubLogin
    Leave GitHub alone entirely: do not offer to copy this host's gh token into the VM, do not
    offer the interactive login, and do not clone. ~/app stays empty. For unattended runs, and
    for repos you would rather clone by hand.

.PARAMETER SkipClaudeLogin
    Do not offer to log Claude Code into the VM. The agent then needs a one-off /login in that
    guest, as before.

.PARAMETER ClaudeTokenPath
    Where the long-lived Claude token is cached on this host. Defaults to
    ~\.agent-vm\claude-oauth-token. Created on first use from `claude setup-token` (a browser
    login against your Claude subscription - no API key, no per-token billing), restricted to
    your account with icacls, and reused for every VM after that. Delete the file to forget it.

.PARAMETER Memory
    Fixed RAM for the guest. Defaults to 10GB, or 6GB when -DeviceSerial is given (no emulator).

.PARAMETER Cpus
    Virtual processor count. Default 4.

.PARAMETER DeviceSerial
    adb serial of a physical phone assigned to this project (DESIGN.md, section 8). When set, the guest
    skips the emulator and pins itself to that device through the host's adb server.

.PARAMETER StartEmulator
    Start the Android emulator with the agent desktop, on every boot, as a window on that
    desktop. Without it the emulator is not running, and the agent (or you) starts it when a
    task needs it: `~/bin/emu -snapshot golden`, a few seconds from the golden snapshot. It
    holds 2 to 4 GB of the VM's RAM while it runs, which a web-only project does not need.
    Not with -DeviceSerial.

.PARAMETER Root
    Where images and VMs live. Defaults to $env:AGENTVM_ROOT, else C:\Hyper-V. -GoldenVhdx and
    -VmRoot derive from it; set AGENTVM_ROOT once (machine scope) to move everything to another
    drive. Must match the -Root used by Build-GoldenImage.ps1 and Remove-AgentVM.ps1.

.PARAMETER HostIp
    Address of the Windows host on the DevSwitch subnet, used for ADB_SERVER_SOCKET.
    Only meaningful together with -DeviceSerial.

.EXAMPLE
    .\New-AgentVM.ps1 -Name app-foo -Repo you/foo
    Asks whether to copy the GitHub and Claude logins, builds the VM, clones the project.

.EXAMPLE
    .\New-AgentVM.ps1 -Name app-game -Repo you/game -DeviceSerial 3A9X0T2K -HostIp 192.168.1.10

.EXAMPLE
    .\New-AgentVM.ps1 -Name app-scratch -SkipGitHubLogin -SkipClaudeLogin
    Empty ~/app, no credentials, no prompts.
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

    [switch]$SkipClaudeLogin,

    [string]$ClaudeTokenPath = "$HOME\.agent-vm\claude-oauth-token",

    [int64]$Memory,

    [ValidateRange(1, 64)]
    [int]$Cpus = 4,

    [string]$DeviceSerial = '',

    [switch]$StartEmulator,

    [string]$HostIp,

    [string]$Root = $(if ($env:AGENTVM_ROOT) { $env:AGENTVM_ROOT } else { 'C:\Hyper-V' }),

    [string]$GoldenVhdx = [IO.Path]::Combine($Root, 'golden', 'golden-ubuntu-rn.vhdx'),

    [string]$VmRoot = [IO.Path]::Combine($Root, 'vms'),

    [string]$SwitchName = 'DevSwitch',

    [string]$SshPublicKeyPath = "$HOME\.ssh\id_ed25519.pub",

    # Generated when omitted; printed once at the end and saved in Credential Manager.
    # Set over SSH after boot, never on the seed ISO. At most 8 characters (VNC's limit).
    [string]$RdpPassword,

    [string]$OscdimgPath = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe',

    [string]$RdpOutputDirectory = $PWD.Path,

    # Seconds to wait for the guest to report a DHCP address.
    [int]$IpTimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# What PowerShell uses when it pipes a string into a native command's stdin - here, the
# credential lines into `ssh` (Invoke-GuestCredentialHandoff). Windows PowerShell defaults
# to ASCII, which turns an accented git name into '?'. Script scope on purpose: an
# assignment inside a function is NOT honoured for the pipe (measured on 5.1), and nothing
# else in this script pipes to a native command.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# ---------------------------------------------------------------- helpers ---

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Note { param([string]$Text) Write-Host "    $Text" -ForegroundColor DarkGray }

function New-RandomPassword {
    param([int]$Length = 8)
    # Alphanumeric only: the value is substituted into YAML and typed into mstsc. Short on
    # purpose - these VMs are reachable only on the local DevSwitch subnet.
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

# ------------------------------------------------- host-side credentials ---

function Get-HostGitHubLogin {
    <#
        What `gh` on this host is logged in as, or $null. The token comes out of the Windows
        keyring via `gh auth token`; the account name and scopes are parsed from
        `gh auth status`, which is display-only - "unknown" there is cosmetic.

        `cmd /c ... 2>&1` rather than PowerShell's own 2>&1: in Windows PowerShell 5.1 a
        native command's stderr redirected in-process becomes ErrorRecords, and with
        $ErrorActionPreference = 'Stop' that is a terminating error. gh writes to stderr
        when it is not logged in, which is precisely the case this has to survive.
    #>
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }

    $token = @(& cmd /c 'gh auth token --hostname github.com 2>nul')
    if ($LASTEXITCODE -ne 0 -or $token.Count -eq 0 -or -not $token[0]) { return $null }

    $status = (@(& cmd /c 'gh auth status --hostname github.com 2>&1') -join "`n")
    $login  = if ($status -match 'Logged in to github\.com (?:account|as) (\S+)') { $Matches[1] } else { 'unknown account' }
    $scopes = if ($status -match 'Token scopes: (.+)') { ($Matches[1] -replace "'", '').Trim() } else { 'unknown' }

    return @{ Token = ([string]$token[0]).Trim(); Login = $login; Scopes = $scopes }
}

function Get-HostGitIdentity {
    # Either field may be empty; git exits 1 for an unset key and prints nothing.
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return @{ Name = ''; Email = '' } }
    $name  = [string](& git config --global user.name)
    $email = [string](& git config --global user.email)
    return @{ Name = $name.Trim(); Email = $email.Trim() }
}

function Save-HostClaudeToken {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Token)

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Token + "`n", (New-Object System.Text.ASCIIEncoding))

    # Strip inherited ACLs and leave only this account. Elevated or not, GetCurrent() is
    # still the logged-in user, so the file stays readable from a normal shell too.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls $Path /inheritance:r /grant:r "${me}:F" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not restrict permissions on $Path (icacls exit $LASTEXITCODE); check them by hand."
    }
    Write-Note "saved to $Path, readable by $me only"
}

function Get-HostClaudeToken {
    <#
        Returns @{ Token; Created } or $null. Created is $true when the token was minted
        just now, so the caller does not ask "use it?" straight after "create it?".

        `claude setup-token` is a full-screen interactive flow (browser login, then a code
        to paste), so it runs uncaptured in this window and the operator pastes the result.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (Test-Path -LiteralPath $Path) {
        $token = (Get-Content -LiteralPath $Path -Raw).Trim()
        if ($token -match '^sk-ant-[A-Za-z0-9_-]+$') { return @{ Token = $token; Created = $false } }
        Write-Warning "$Path does not look like a Claude token (expected sk-ant-...); ignoring it."
    }

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Note "no cached token at $Path and no `claude` on PATH; the VM will need /login by hand."
        return $null
    }

    Write-Note "No cached token at $Path."
    Write-Note '`claude setup-token` mints a long-lived token for your Claude *subscription* - not an API'
    Write-Note 'key, nothing billed per token. It opens a browser login on this host and prints the token;'
    Write-Note "paste it back here. It is then cached at $Path for every later VM."
    if (-not (Read-YesNo -Question '  Run `claude setup-token` now?')) { return $null }

    Write-Host ''
    & claude setup-token
    Write-Host ''

    $secure = Read-Host '  Paste the token it printed (sk-ant-oat01-...)' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

    if ($token -notmatch '^sk-ant-[A-Za-z0-9_-]+$') {
        Write-Warning 'That does not look like a Claude token; skipping the Claude login for this VM.'
        return $null
    }
    Save-HostClaudeToken -Path $Path -Token $token
    return @{ Token = $token; Created = $true }
}

# ---------------------------------------------------------- guest steps ---

$script:SshOpts = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=10')

function Initialize-GuestSetup {
    <#
        Everything the post-boot steps share: the OpenSSH client, sshd answering, a clean
        known_hosts entry, cloud-init finished, and the setup script in /tmp. Returns $true
        when the guest is ready for `bash /tmp/agentvm-setup.sh ...`.
    #>
    param([Parameter(Mandatory)][string]$IpAddress, [Parameter(Mandatory)][string]$SetupScript)

    foreach ($tool in 'ssh', 'scp') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Warning "$tool is not on PATH; skipping the post-boot setup. Add the Windows OpenSSH client (Settings > Optional features)."
            return $false
        }
    }

    Write-Step "Waiting for SSH on $IpAddress"
    if (-not (Wait-ForSsh -IpAddress $IpAddress)) {
        Write-Warning "No SSH on $IpAddress after 240 s; skipping the post-boot setup."
        return $false
    }

    Clear-StaleHostKey -IpAddress $IpAddress
    $target = "dev@$IpAddress"

    # sshd answers before cloud-init has finished, and runcmd is what creates ~/app. Waiting
    # here keeps the clone from racing it. `exit 0` because a non-zero cloud-init status
    # (deprecation warnings alone will do it) is not a reason to abandon the setup.
    Write-Step 'Waiting for first boot to finish'
    & ssh @script:SshOpts $target 'cloud-init status --wait >/dev/null 2>&1; exit 0'

    # Shipped by scp rather than piped into `bash -s`: PowerShell would terminate the piped
    # string with CRLF and bash treats the stray \r as part of the last command.
    $localScript = Join-Path ([IO.Path]::GetTempPath()) ('agentvm-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sh')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($localScript, ($SetupScript -replace "`r`n", "`n"), $utf8NoBom)
    try {
        & scp @script:SshOpts $localScript "${target}:/tmp/agentvm-setup.sh"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not copy the setup script to the guest (scp exit $LASTEXITCODE); skipping the post-boot setup."
            return $false
        }
    }
    finally {
        Remove-Item -LiteralPath $localScript -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Invoke-GuestCredentialHandoff {
    <#
        Feeds KEY=value lines to the guest script on stdin. stdin, not arguments: an
        argument shows up in `ps` inside the guest and in sshd's logging; a pipe is seen by
        bash and nothing else. The guest strips the \r PowerShell puts on each line.
    #>
    param([Parameter(Mandatory)][string]$IpAddress, [Parameter(Mandatory)][System.Collections.IDictionary]$Payload)

    $lines = foreach ($key in $Payload.Keys) { '{0}={1}' -f $key, $Payload[$key] }
    $text  = ($lines -join "`n") + "`n"

    # Encoding is $OutputEncoding, set at the top of the script. Windows PowerShell also
    # puts a UTF-8 BOM in front of the first line and CRLF after the last, whatever the
    # encoding says; the guest strips both.
    $text | & ssh @script:SshOpts "dev@$IpAddress" 'bash /tmp/agentvm-setup.sh credentials'
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The credential hand-off exited $LASTEXITCODE - see the output above. The VM may need its logins done by hand."
        return $false
    }
    return $true
}

function Invoke-GuestClone {
    <#
        Clones into ~/app. Interactive only if gh still has to log in; with the token
        already handed over it just runs. Returns $true only if the whole thing succeeded,
        so the caller can tell the operator what ~/app actually contains rather than guessing.
    #>
    param([Parameter(Mandatory)][string]$IpAddress, [Parameter(Mandatory)][string]$Repo)

    # -t forces a TTY: without it gh sees a non-interactive stdin and refuses to prompt,
    # and npm's progress output is nicer with one either way.
    & ssh @script:SshOpts -t "dev@$IpAddress" "bash /tmp/agentvm-setup.sh clone '$Repo'"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "The guest clone step exited $LASTEXITCODE - see the output above. ~/app may be empty or partially set up."
        return $false
    }
    return $true
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
    throw 'The Hyper-V PowerShell module is not available. Enable the Hyper-V feature first (DESIGN.md, section 2).'
}

if (-not (Test-Path -LiteralPath $GoldenVhdx)) {
    throw "Golden image not found: $GoldenVhdx. Build it first: packer\Build-GoldenImage.ps1."
}

if (-not (Test-Path -LiteralPath $OscdimgPath)) {
    throw "oscdimg.exe not found: $OscdimgPath. Install the Windows ADK Deployment Tools, or pass -OscdimgPath."
}

if (-not (Test-Path -LiteralPath $SshPublicKeyPath)) {
    throw "SSH public key not found: $SshPublicKeyPath. Pass -SshPublicKeyPath."
}

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    throw "Virtual switch '$SwitchName' does not exist. Create it once (DESIGN.md, section 2)."
}

if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    throw "A VM named '$Name' already exists. Remove it with .\Remove-AgentVM.ps1 -Name $Name first."
}

$vmPath = Join-Path $VmRoot $Name
if (Test-Path -LiteralPath $vmPath) {
    throw "Project folder already exists: $vmPath. Remove it before recreating the VM."
}

if (-not $Memory) {
    # Phone-backed VMs run no emulator, so they need markedly less RAM (DESIGN.md, section 8).
    $Memory = if ($DeviceSerial) { 6GB } else { 10GB }
}

if ($DeviceSerial -and -not $HostIp) {
    throw '-DeviceSerial requires -HostIp: the guest talks to the adb server running on the host (DESIGN.md, section 8).'
}

if ($DeviceSerial -and $StartEmulator) {
    throw '-StartEmulator and -DeviceSerial exclude each other: a phone-backed VM runs no emulator.'
}

if (-not $RdpPassword) { $RdpPassword = New-RandomPassword }

# Set-AgentVMPassword.ps1 applies it once the VM is up and rejects anything outside this
# pattern; checked here so that does not happen after the VM has been built.
if ($RdpPassword -notmatch '^[A-Za-z0-9!#%+,./:=?@^_~-]{1,8}$') {
    throw '-RdpPassword: 1 to 8 letters, digits or !#%+,./:=?@^_~- (VNC ignores anything past 8; no spaces or quotes).'
}
$setPasswordScript = Join-Path $PSScriptRoot 'Set-AgentVMPassword.ps1'
if (-not (Test-Path -LiteralPath $setPasswordScript)) {
    throw "Set-AgentVMPassword.ps1 is missing from $PSScriptRoot; it sets the VM's password."
}

$sshPublicKey = (Get-Content -LiteralPath $SshPublicKeyPath -Raw).Trim()

Write-Step "Creating dev VM '$Name'"
Write-Note ("memory {0} GB, {1} vCPU, switch {2}" -f ($Memory / 1GB), $Cpus, $SwitchName)
if ($DeviceSerial) {
    Write-Note "render target: physical device $DeviceSerial via adb server tcp:${HostIp}:5037"
} elseif ($StartEmulator) {
    Write-Note 'render target: AVD emulator, started with the agent desktop at every boot'
} else {
    Write-Note 'render target: AVD emulator, started on demand (~/bin/emu -snapshot golden)'
}

# ------------------------------------------------------ host credentials ---
#
# Asked now, before the two-minute build, so the wait is uninterrupted; delivered over SSH
# after first boot (Invoke-GuestCredentialHandoff). Nothing here goes near the seed ISO.

$handoff       = [ordered]@{}
$handoffGitHub = $false
$handoffClaude = $false
$ghLogin       = $null
$gitIdentity   = @{ Name = ''; Email = '' }

if (-not $SkipGitHubLogin) {
    Write-Host ''
    Write-Step 'GitHub'
    $ghLogin     = Get-HostGitHubLogin
    $gitIdentity = Get-HostGitIdentity
    if ($ghLogin) {
        Write-Note "this host: gh is logged in as $($ghLogin.Login)  (token scopes: $($ghLogin.Scopes))"
        if ($gitIdentity.Name -or $gitIdentity.Email) {
            Write-Note ("           git commits as {0} <{1}>" -f $gitIdentity.Name, $gitIdentity.Email)
        } else {
            Write-Note '           no global git user.name / user.email set here'
        }
        Write-Note 'Yes: after boot, this token goes into the VM (gh auth login --with-token, gh auth setup-git)'
        Write-Note '     along with the git identity. The VM then SHARES the token with this host: revoking it'
        Write-Note '     at github.com/settings/applications logs both out. Inside the guest it sits in'
        Write-Note '     ~/.config/gh/hosts.yml in plain text, like any headless gh login.'
        Write-Note 'No:  with -Repo, an interactive gh auth login in the guest is offered at the end instead,'
        Write-Note '     which gives that VM a token of its own.'
        if (Read-YesNo -Question '  Copy your GitHub login into this VM?') {
            $handoff['GH_TOKEN'] = $ghLogin.Token
            if ($gitIdentity.Name)  { $handoff['GIT_USER_NAME']  = $gitIdentity.Name }
            if ($gitIdentity.Email) { $handoff['GIT_USER_EMAIL'] = $gitIdentity.Email }
            $handoffGitHub = $true
        } else {
            Write-Note 'Not copied.'
        }
    } else {
        Write-Note 'gh is not installed or not logged in on this host - nothing to copy.'
        if ($Repo) { Write-Note 'The GitHub login will be interactive, in the guest, at the end.' }
    }
}

if (-not $SkipClaudeLogin) {
    Write-Host ''
    Write-Step 'Claude Code'
    $claude = Get-HostClaudeToken -Path $ClaudeTokenPath
    if ($claude) {
        if ($claude.Created) {
            $useClaude = $true
        } else {
            Write-Note "cached subscription token: $ClaudeTokenPath"
            Write-Note 'Yes: after boot it is written to ~/.claude/settings.json in the VM as CLAUDE_CODE_OAUTH_TOKEN.'
            Write-Note '     The CLI and the VS Code extension are logged in from their first launch; usage is'
            Write-Note '     billed to your subscription, exactly as /login would be. It overrides /login in that'
            Write-Note '     VM - delete the env entry from that file to switch accounts there.'
            Write-Note 'No:  log the agent in by hand later (ssh in, run claude, /login).'
            $useClaude = Read-YesNo -Question '  Log Claude Code into this VM with it?'
        }
        if ($useClaude) {
            $handoff['CLAUDE_CODE_OAUTH_TOKEN'] = $claude.Token
            $handoffClaude = $true
        } else {
            Write-Note 'Not copied.'
        }
    }
}
Write-Host ''

# ----------------------------------------------------- disk, VM, hardware ---

New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

$diskPath = Join-Path $vmPath 'disk.vhdx'
$seedIso  = Join-Path $vmPath 'seed.iso'

Write-Step 'Creating differencing disk'
New-VHD -Path $diskPath -ParentPath $GoldenVhdx -Differencing | Out-Null

Write-Step 'Creating the VM'
New-VM -Name $Name -Generation 2 -MemoryStartupBytes $Memory `
       -VHDPath $diskPath -SwitchName $SwitchName -Path $VmRoot | Out-Null

# Nested virtualization requires static memory and forbids checkpoints (DESIGN.md, section 5).
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
# No password here. This file stays attached to the VM as seed.iso and is readable from
# inside it, so the RDP password is set over SSH once the VM is up (Set-AgentVMPassword.ps1).
write_files:
  - path: /home/dev/.env
    owner: dev:dev
    permissions: '0600'
    content: |
      # No credentials here - this file comes off the seed ISO, which stays attached to the
      # VM. Claude Code's subscription token, if New-AgentVM.ps1 handed one over after boot,
      # is in ~/.claude/settings.json; otherwise run `claude` and /login once.
      PROJECT=${NAME}
      # Physical device mode (DESIGN.md, section 8). An empty ANDROID_SERIAL means the emulator.
      ADB_SERVER_SOCKET=${ADB_SERVER_SOCKET}
      ANDROID_SERIAL=${DEVICE_SERIAL}
${EMULATOR_AUTOSTART}
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
  # exist so the agent's tmux session has a working directory.
  - [sudo, -u, dev, mkdir, -p, /home/dev/app]
  # Nothing for the agent desktop (10-desktop-xrdp.sh): it starts once Set-AgentVMPassword.ps1
  # has given it a password over SSH, and from then on at every boot. Its autostart opens the
  # agent's tmux session inside it, with DISPLAY=:1.
  #
  # runcmd runs only on the FIRST boot of an instance. Anything that has to be running after
  # every boot belongs in systemd or the desktop's autostart, never only here.
  #
  # An image from before the agent desktop has no vncpasswd; it gets the old detached tmux
  # session instead, which has no display.
  - [sudo, -u, dev, bash, -c, 'command -v vncpasswd >/dev/null || tmux new -d -s agent -c /home/dev/app']
  # No emulator here. It used to start from runcmd, which only ever happens on the first
  # boot, and headless, since nothing here has a display. With -StartEmulator it is in the
  # agent desktop's autostart instead (write_files above): every boot, as a window.
  # Otherwise the agent starts it when a task needs it.
'@

# -StartEmulator: an autostart entry for the agent desktop, so the emulator comes up with it
# at every boot, with DISPLAY=:1 and therefore as a window (~/bin/emu only goes headless when
# DISPLAY is unset). `defer` writes it after the users stage. Nothing here runs adb: host
# access is adb-bridge.service, and `adb tcpip 5555` would knock the emulator off this VM's
# own adb server (DESIGN.md, section 8).
$emulatorAutostart = @'
  - path: /home/dev/.config/autostart/android-emulator.desktop
    owner: dev:dev
    permissions: '0644'
    defer: true
    content: |
      [Desktop Entry]
      Type=Application
      Name=Android emulator
      Comment=Written by New-AgentVM.ps1 -StartEmulator
      Exec=bash -lc "unset ADB_SERVER_SOCKET; exec ~/bin/emu -snapshot golden >/tmp/emu.log 2>&1"
'@

$metaDataTemplate = @'
instance-id: ${NAME}-${INSTANCE}
local-hostname: ${NAME}
'@

# Copied to /tmp/agentvm-setup.sh in the guest once it is up, and left there so a declined or
# failed step can be re-run by hand. Two entry points:
#
#   credentials   KEY=value lines on stdin; no TTY. Logs gh in with the host's token, sets
#                 the git identity, writes the Claude token into ~/.claude/settings.json.
#   clone <repo>  Over `ssh -t`. Logs in interactively if the token was not handed over,
#                 clones into ~/app, npm install.
#
# The gh binary comes from the golden image (25-ide-browser.sh); ensure_gh below only
# installs it on an image built before that step existed. Everything else - the known_hosts
# entry and every token - is installed per VM, at the moment someone asks for it.
$guestSetupScript = @'
#!/usr/bin/env bash
# Written by New-AgentVM.ps1.
#   bash /tmp/agentvm-setup.sh credentials   < KEY=value lines   (GH_TOKEN, GIT_USER_NAME,
#                                             GIT_USER_EMAIL, CLAUDE_CODE_OAUTH_TOKEN)
#   bash /tmp/agentvm-setup.sh clone <repo>   interactive if gh is not logged in yet
set -euo pipefail

APP=/home/dev/app

ensure_gh() {
    if command -v gh >/dev/null 2>&1; then return; fi
    echo "==> installing the GitHub CLI (not in this golden image; images built after 25-ide-browser.sh added it have it already)"
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
}

do_credentials() {
    local gh_token='' git_name='' git_email='' claude_token='' line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#$'\xEF\xBB\xBF'}"  # Windows PowerShell puts a UTF-8 BOM before the first line
        line="${line%$'\r'}"            # ... and CRLF after the last
        [ -z "$line" ] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            GH_TOKEN)                gh_token="$value" ;;
            GIT_USER_NAME)           git_name="$value" ;;
            GIT_USER_EMAIL)          git_email="$value" ;;
            CLAUDE_CODE_OAUTH_TOKEN) claude_token="$value" ;;
            *) echo "credentials: unexpected key '${key}' on stdin" >&2; exit 2 ;;
        esac
    done

    if [ -n "$gh_token" ]; then
        ensure_gh
        gh --version | head -n1
        echo "==> gh auth login --with-token"
        # Via a pipe, never an argument: an argument would be visible in `ps`.
        printf '%s' "$gh_token" | gh auth login --hostname github.com --with-token
        # Point git itself at the token, so pushes from inside the VM do not prompt.
        gh auth setup-git
        echo "    logged in as $(gh api user --jq .login 2>/dev/null || echo '<could not query>')"
    fi

    if [ -n "$git_name" ];  then git config --global user.name  "$git_name";  fi
    if [ -n "$git_email" ]; then git config --global user.email "$git_email"; fi
    if [ -n "${git_name}${git_email}" ]; then
        echo "==> git identity: ${git_name} <${git_email}>"
    fi

    if [ -n "$claude_token" ]; then
        # The `env` block of the user settings file is applied to every Claude Code session,
        # CLI and VS Code extension alike, before authentication is resolved - so this is
        # the one place that covers both. It also wins over any later /login in this VM.
        echo "==> Claude Code: CLAUDE_CODE_OAUTH_TOKEN -> ~/.claude/settings.json"
        mkdir -p ~/.claude && chmod 700 ~/.claude
        local settings=~/.claude/settings.json tmp
        [ -f "$settings" ] || echo '{}' > "$settings"
        tmp="$(mktemp)"
        jq --arg t "$claude_token" '.env.CLAUDE_CODE_OAUTH_TOKEN = $t' "$settings" > "$tmp"
        mv "$tmp" "$settings"
        chmod 600 "$settings"
        # No API call: reports how the CLI will authenticate, not whether the server agrees.
        claude auth status --text 2>/dev/null | sed 's/^/    /' || true
    fi
}

do_clone() {
    local repo="$1" host

    ensure_gh
    gh --version | head -n1

    if gh auth status >/dev/null 2>&1; then
        echo "==> already authenticated to GitHub"
    else
        echo "==> gh auth login  (answer the prompts below)"
        gh auth login
    fi
    gh auth setup-git

    # An SSH-form URL needs the host key up front: this runs with a TTY but nobody wants to
    # answer "authenticity of host can't be established" mid-clone, and a non-GitHub host
    # would otherwise fail outright. Per VM, only for the host actually being cloned from.
    case "$repo" in
        git@*|ssh://*)
            host="$(printf '%s' "$repo" | sed -E 's|^ssh://||; s|^[^@]*@||; s|[:/].*$||')"
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
        echo "==> cloning ${repo}"
        # runcmd created ~/app empty. git refuses to clone into a non-empty directory but is
        # perfectly happy with an empty one, so there is nothing to clean up first.
        if printf '%s' "$repo" | grep -qE '(^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$)|github\.com'; then
            gh repo clone "$repo" "$APP"
        else
            echo "    not a GitHub repo - using plain git"
            git clone "$repo" "$APP"
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
}

case "${1:-}" in
    credentials) do_credentials ;;
    clone)       do_clone "${2:?usage: agentvm-setup.sh clone <repo>}" ;;
    *) echo "usage: agentvm-setup.sh credentials < KEY=value lines | clone <repo>" >&2; exit 2 ;;
esac
'@

# A phone-backed guest points its adb client at the host's server; an emulator guest keeps
# the local default (DESIGN.md, section 8).
$adbServerSocket = if ($DeviceSerial) { "tcp:${HostIp}:5037" } else { '' }
$substitutions = [ordered]@{
    '${EMULATOR_AUTOSTART}' = $(if ($StartEmulator) { $emulatorAutostart } else { '' })
    '${NAME}'              = $Name
    '${SSH_PUBKEY}'        = $sshPublicKey
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
    Write-Warning "No address reported within $IpTimeoutSeconds s. The VM is running - check the Hyper-V console or your DHCP leases."
    Write-Host ''
    Write-Host "VM '$Name' has no RDP password and no agent desktop yet. Once it has an address:"
    Write-Host "  .\Set-AgentVMPassword.ps1 -Name $Name -Password $RdpPassword"
    return
}

# ------------------------------------------------------------- .rdp file ---

# Lossless settings (DESIGN.md, section 6): 32-bit colour, no compression, smart sizing off,
# so one guest pixel maps to one host pixel.
$rdpPath = Join-Path $RdpOutputDirectory "$Name.rdp"
$rdpContent = @"
full address:s:$ip
username:s:dev
prompt for credentials:i:0
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

# ------------------------------------------------------------ RDP password ---

# Every post-boot step needs SSH and a finished first boot; this waits for both once.
$guestReady = Initialize-GuestSetup -IpAddress $ip -SetupScript $guestSetupScript

# The password is set here, over SSH, and never written to the seed ISO. Set-AgentVMPassword.ps1
# also starts the agent desktop, which cannot start without one, and saves the password in
# Credential Manager as TERMSRV/<address>: mstsc sends that entry with the connection and
# xrdp hands it to the desktop's VNC check, so the .rdp file opens with no dialog.
$passwordSet = $false
if ($guestReady) {
    Write-Step 'Setting the RDP password'
    try {
        & $setPasswordScript -Name $Name -IpAddress $ip -Password $RdpPassword -VmRoot $VmRoot
        $passwordSet = $true
    }
    catch {
        Write-Warning "Setting the password failed: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------- connect info ---

Write-Host ''
Write-Step "'$Name' is up at $ip"
Write-Host ''
Write-Host "  SSH + agent : ssh dev@$ip -t tmux attach -t agent"
if ($passwordSet) {
    Write-Host "  RDP         : $rdpPath   (agent desktop, no prompt; password $RdpPassword in Credential Manager)"
} else {
    Write-Host "  RDP         : $rdpPath   NOT usable yet - no password. Run: .\Set-AgentVMPassword.ps1 -Name $Name -IpAddress $ip -Password $RdpPassword" -ForegroundColor Yellow
}
if ($DeviceSerial) {
    Write-Host "  Device      : $DeviceSerial via the host adb server, tcp:${HostIp}:5037"
    Write-Host "  Screen      : scrcpy -s $DeviceSerial          # on the host, over USB"
} else {
    if (-not $StartEmulator) {
        Write-Host "  Emulator    : not running; in the guest: ~/bin/emu -snapshot golden   (agent session, a few seconds)"
    }
    Write-Host "  Emulator adb: adb connect ${ip}:5555            # on the host, once it runs"
    # NOT `exec-out screencap -p > screen.png`. PowerShell's `>` is a text redirect: it
    # decodes the PNG bytes as text and re-encodes them as UTF-8 with a BOM, and the file
    # that lands is not a PNG. screencap-to-file plus pull is byte-exact in every shell.
    Write-Host "  Screenshot  : adb -s ${ip}:5555 shell screencap -p /sdcard/s.png; adb -s ${ip}:5555 pull /sdcard/s.png screen.png"
}
Write-Host "  Metro       : http://${ip}:8081"
Write-Host ''

# ------------------------------------------ credentials and checkout ---

# $guestReady comes from the RDP password step above, which waited for the guest once.
$handoffOk  = $false
$repoReady  = $false
$wantClone  = [bool]($Repo -and -not $SkipGitHubLogin)

if ($handoff.Count -gt 0 -and $guestReady) {
    Write-Step "Handing over credentials to $ip"
    $handoffOk = Invoke-GuestCredentialHandoff -IpAddress $ip -Payload $handoff
}

if ($wantClone -and $guestReady) {
    Write-Host ''
    if ($handoffGitHub -and $handoffOk) {
        Write-Step "Cloning $Repo into ~/app"
        $repoReady = Invoke-GuestClone -IpAddress $ip -Repo $Repo
    }
    else {
        Write-Host "  Project     : $Repo" -ForegroundColor Cyan
        Write-Note 'Logging in installs the GitHub CLI in this VM and gives it a token of its own.'
        Write-Note 'Nothing is written to the golden image, and no credential goes on the seed ISO.'
        Write-Note 'gh prints a one-time code and opens a browser flow; answer its prompts here.'
        Write-Host ''
        if (Read-YesNo -Question '  Log into GitHub in this VM and clone the project now?') {
            $repoReady = Invoke-GuestClone -IpAddress $ip -Repo $Repo
        }
        else {
            Write-Note 'Skipped. ~/app is empty.'
        }
    }
    Write-Host ''
}

# ----------------------------------------------------------------- summary ---

Write-Step "'$Name' summary"

if ($handoffGitHub) {
    if ($handoffOk) {
        Write-Note "GitHub: gh and git in the VM use this host's token ($($ghLogin.Login)); revoking it logs both out."
    } else {
        Write-Note 'GitHub: the token hand-off FAILED (see above); gh in the VM is not logged in.'
    }
}

if ($Repo -and $repoReady) {
    Write-Note "~/app has $Repo checked out, dependencies installed."
}
elseif ($Repo) {
    Write-Note "~/app is EMPTY. To finish the checkout: ssh dev@$ip -t ""bash /tmp/agentvm-setup.sh clone '$Repo'"""
    Write-Note "Or clone it yourself over agent forwarding: ssh -A dev@$ip"
}
else {
    Write-Note '~/app is empty - no -Repo was given.'
}

Write-Note "Lost the password? .\Get-AgentVMPassword.ps1 -Name $Name   (or set one: .\Set-AgentVMPassword.ps1)"
if ($StartEmulator) {
    Write-Note 'The emulator is resuming from the golden snapshot on the agent desktop; give it a few seconds.'
}

if ($handoffClaude -and $handoffOk) {
    Write-Note "Claude Code is logged in via the token in ~/.claude/settings.json (from $ClaudeTokenPath)."
    Write-Note "Verify: ssh dev@$ip claude -p 'say ok'"
}
else {
    if ($handoffClaude) { Write-Note 'Claude: the token hand-off FAILED (see above).' }
    Write-Note "Log the agent in once in this VM: ssh dev@$ip -t claude   (then /login, subscription account)."
}
