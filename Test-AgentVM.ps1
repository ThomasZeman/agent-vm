<#
.SYNOPSIS
    Smoke-tests an agent VM cloned from the golden image: everything the image and
    New-AgentVM.ps1 promise, and every fix that once failed silently.

.DESCRIPTION
    Runs from the host, like the other scripts. A bash suite goes to the guest over SSH on
    stdin and reports one line per check; the host supplies what only it knows - its own
    time zone, locale and clock, the VM's RDP resolution - and checks its own side of the
    VM (the .rdp file, the Credential Manager entries).

    Each check names the fix it protects, so a FAIL points at the commit to read:

      cloud-init, seed     runcmd that silently died (2714d86, 9640387); no password on the
                           seed ISO (cff701c)
      time, locale         the guest reads time and language like the host, so the browser in
                           it does too (time zone / locale baked in by Build-GoldenImage.ps1)
      desktop              the agent desktop on :1 from boot, RDP onto it (93b1502); fixed at
                           -RdpResolution (92714c4); no blanking
      chrome               no keyring or first-run dialog on a fresh profile (cb2054e); the
                           Claude in Chrome policy (ba02431); what a web page can see,
                           WebGL on llvmpipe included
      docker               engine, group, log driver, and Alpine DNS through resolved (2379fc2)
      android              adb-bridge not forking on loopback (9640387); emu off the login PATH
                           (a0f5b48); the golden snapshot; libxcb-cursor0
      claude, tools        CLI, VS Code extension, project-agnostic CLAUDE.md (85c144b), gh
                           (744e424), Node, JDK, Playwright browsers

    PASS and FAIL mean what they say. WARN is something that is merely slow (the extension
    download), so it does not fail the run. The exit code is the number of FAILs.

    The Chrome checks start a real, headful Chrome on the agent desktop with a throwaway
    profile - briefly visible over RDP - and remove it afterwards. The Docker check pulls
    Alpine (~4 MB) and removes it again unless it was already there.

    Needs no elevation unless the VM is looked up through Hyper-V (no -Address and no .rdp
    file).

.PARAMETER Name
    The VM, as given to New-AgentVM.ps1. Used to find <Name>.rdp and the Credential Manager
    entries.

.PARAMETER Address
    The VM's IP address. Defaults to the one in <RdpOutputDirectory>\<Name>.rdp, then to
    Hyper-V's view of the VM (elevated only).

.PARAMETER RdpOutputDirectory
    Where New-AgentVM.ps1 wrote <Name>.rdp. Defaults to the current directory, as there.

.PARAMETER IncludeEmulator
    Also boot the emulator from the golden snapshot (headless) and wait for Android to
    finish booting. Off by default: it takes a minute and 2 to 4 GB of the VM's RAM, and it
    is the heaviest thing the host does for these VMs.

.EXAMPLE
    .\Test-AgentVM.ps1 -Name vm1

.EXAMPLE
    .\Test-AgentVM.ps1 -Name vm1 -IncludeEmulator
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,30}$')]
    [string]$Name,

    [ValidatePattern('^[0-9a-fA-F:.]+$')]
    [string]$Address,

    [string]$RdpOutputDirectory = $PWD.Path,

    [string]$User = 'dev',

    [switch]$IncludeEmulator
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# What PowerShell uses to pipe the suite into ssh; Windows PowerShell defaults to ASCII.
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

. ([IO.Path]::Combine($PSScriptRoot, 'lib', 'HostLocale.ps1'))

$results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string]$Status, [string]$Id, [string]$Detail)
    $results.Add([pscustomobject]@{ Status = $Status; Check = $Id; Detail = $Detail })
}

# ----------------------------------------------------------- host side ---

$rdpPath = Join-Path $RdpOutputDirectory "$Name.rdp"
$rdp = if (Test-Path -LiteralPath $rdpPath) { Get-Content -LiteralPath $rdpPath } else { @() }
$rdpAddress = ($rdp | Where-Object { $_ -like 'full address:s:*' } | Select-Object -First 1) -replace '^full address:s:', ''

if (-not $Address) { $Address = $rdpAddress }
if (-not $Address) {
    try {
        $Address = @((Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop).IPAddresses) |
            Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    }
    catch {
        throw "No address for '$Name': no $rdpPath, and Hyper-V could not be asked ($($_.Exception.Message)). Pass -Address."
    }
}
if (-not $Address) { throw "No address for '$Name'. Pass -Address." }

if ($rdp) {
    Add-Result PASS 'host.rdp-file' $rdpPath
}
else {
    Add-Result FAIL 'host.rdp-file' "$rdpPath not found"
}

# New-AgentVM.ps1 opens the desktop at exactly the size the .rdp asks for (92714c4).
$width = ($rdp | Where-Object { $_ -like 'desktopwidth:i:*' }) -replace '^desktopwidth:i:', ''
$height = ($rdp | Where-Object { $_ -like 'desktopheight:i:*' }) -replace '^desktopheight:i:', ''
$expectRes = if ($width -and $height) { "${width}x${height}" } else { '1920x1080' }

# The password lives only in Credential Manager (cff701c): TERMSRV/<address> for mstsc and
# agent-vm:<Name> for Get-AgentVMPassword.ps1.
foreach ($target in @("TERMSRV/$Address", "agent-vm:$Name")) {
    $listed = (cmdkey "/list:$target" 2>$null) -join "`n"
    if ($listed -match [regex]::Escape($target)) {
        Add-Result PASS 'host.credential' $target
    }
    else {
        Add-Result FAIL 'host.credential' "$target is not in Credential Manager"
    }
}

$expectTz = Get-HostIanaTimeZone
$expectLang = Get-HostLocale

# ---------------------------------------------------------- guest suite ---

$suite = @'
#!/usr/bin/env bash
# Agent VM smoke test, guest side. Sent by Test-AgentVM.ps1 over stdin; prints one
# "RESULT<TAB>status<TAB>check<TAB>detail" line per check. No set -e: every check runs.
EXPECT_TZ="$1"; EXPECT_LANG="$2"; EXPECT_RES="$3"; HOST_EPOCH="$4"; INCLUDE_EMULATOR="$5"
GUEST_EPOCH="$(date +%s.%N)"
export DISPLAY=:1

r() { printf 'RESULT\t%s\t%s\t%s\n' "$1" "$2" "${3//$'\n'/ }"; }
ok() { if [ "$1" -eq 0 ]; then r PASS "$2" "$3"; else r FAIL "$2" "$3"; fi; }

# ------------------------------------------------------------ first boot ---
# cloud-init exits 0 when done, 2 when it finished with recoverable errors - which is how
# a runcmd entry dies silently while the VM looks healthy (2714d86, 9640387).
cloud-init status >/dev/null 2>&1; rc=$?
case $rc in
    0) r PASS cloud-init.done "$(cloud-init status 2>/dev/null | head -1)" ;;
    2) r FAIL cloud-init.done "finished with errors: $(cloud-init status --long 2>/dev/null | grep -A3 '^errors' | tr -s ' ' | head -c 300)" ;;
    *) r FAIL cloud-init.done "status exit $rc: $(cloud-init status 2>&1 | head -1)" ;;
esac

# The seed ISO stays attached and readable for the VM's life: no password may be on it (cff701c).
if sudo -n test -r /var/lib/cloud/instance/user-data.txt; then
    hits="$(sudo -n grep -Ein 'chpasswd|plain_text_passwd|hashed_passwd|^[[:space:]]*passwd:|lock_passwd:[[:space:]]*false' /var/lib/cloud/instance/user-data.txt | head -3)"
    if [ -z "$hits" ]; then r PASS seed.no-password 'user-data carries no password'; else r FAIL seed.no-password "$hits"; fi
else
    r FAIL seed.no-password 'cannot read /var/lib/cloud/instance/user-data.txt'
fi

sudo -n true 2>/dev/null; ok $? sudo.nopasswd 'sudo -n works'

# ---------------------------------------------------------- time, locale ---
tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
[ "$tz" = "$EXPECT_TZ" ]; ok $? time.zone "guest $tz, host $EXPECT_TZ"

delta="$(awk -v a="$GUEST_EPOCH" -v b="$HOST_EPOCH" 'BEGIN { d = a - b; if (d < 0) d = -d; printf "%.2f", d }')"
awk -v d="$delta" 'BEGIN { exit !(d < 3) }'
ok $? time.clock "guest-host difference ${delta}s, SSH setup included (Hyper-V time sync)"
# A VM a few minutes old may not have had its first NTP exchange yet; give it a minute.
for i in $(seq 1 12); do
    synced="$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    [ "$synced" = yes ] && break; sleep 5
done
if [ "$synced" = yes ]; then r PASS time.ntp 'NTP synchronized'; else r WARN time.ntp 'NTP not synchronized after 60s'; fi

lang="$(sed -n 's/^LANG=//p' /etc/default/locale | tr -d '"')"
[ "$lang" = "$EXPECT_LANG" ]; ok $? locale.system "LANG $lang, host $EXPECT_LANG"

want="$(echo "$EXPECT_LANG" | sed 's/\.UTF-8$/.utf8/')"
locale -a 2>/dev/null | grep -qx "$want"; ok $? locale.generated "$want in locale -a"

session="$(pgrep -o -u "$USER" xfce4-session)"
if [ -n "$session" ]; then
    slang="$(tr '\0' '\n' < "/proc/$session/environ" | sed -n 's/^LANG=//p')"
    [ "$slang" = "$EXPECT_LANG" ]; ok $? locale.desktop "agent desktop LANG $slang"
else
    r FAIL locale.desktop 'no xfce4-session running'
fi

# --------------------------------------------------------------- desktop ---
# One XFCE session on :1, started at boot, bound to loopback; RDP attaches to it (93b1502).
[ "$(systemctl is-active tigervncserver@:1 2>/dev/null)" = active ]; ok $? desktop.vnc 'tigervncserver@:1 active'

exposed="$(ss -ltnH 'sport = :5901' 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.0\.0\.1|\[::1\]):5901$')"
listening="$(ss -ltnH 'sport = :5901' 2>/dev/null | wc -l)"
[ "$listening" -gt 0 ] && [ -z "$exposed" ]; ok $? desktop.vnc-loopback "listeners: $(ss -ltnH 'sport = :5901' | awk '{print $4}' | tr '\n' ' ')"

res="$(xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}')"
[ "$res" = "$EXPECT_RES" ]; ok $? desktop.resolution "desktop $res, .rdp $EXPECT_RES"

grep -qx 'AcceptSetDesktopSize=0' "$HOME/.vnc/config" 2>/dev/null; ok $? desktop.resize-locked 'AcceptSetDesktopSize=0 (92714c4)'

first="$(grep -m1 -E '^\[(Agent|Xorg|Xvnc|vnc-any|neutrinordp-any)\]' /etc/xrdp/xrdp.ini)"
[ "$(systemctl is-active xrdp)" = active ] && [ "$first" = '[Agent]' ] && ss -ltnH 'sport = :3389' | grep -q .
ok $? desktop.xrdp "xrdp active on 3389, first session entry $first"

pane="$(tmux list-panes -t agent -F '#{pane_pid}' 2>/dev/null | head -1)"
if [ -n "$pane" ]; then
    pdisplay="$(tr '\0' '\n' < "/proc/$pane/environ" | sed -n 's/^DISPLAY=//p')"
    echo "$pdisplay" | grep -qxE ':1(\.0)?'; ok $? desktop.agent-session "tmux 'agent' pane DISPLAY=$pdisplay"
else
    r FAIL desktop.agent-session "no tmux session 'agent'"
fi

ssto="$(xset q 2>/dev/null | awk '/timeout:/ {print $2; exit}')"
[ "$ssto" = 0 ]; ok $? desktop.no-blanking "screensaver timeout ${ssto:-?}"

# ---------------------------------------------------------------- chrome ---
# Every launcher goes through the wrapper that keeps Chrome out of the keyring and the
# first-run dialog (cb2054e).
wrapper=/usr/bin/google-chrome-stable
dpkg-divert --list "$wrapper" 2>/dev/null | grep -q 'google-chrome-stable.distrib' \
    && grep -q -- '--password-store=basic' "$wrapper" && grep -q -- '--no-first-run' "$wrapper" \
    && grep -q -- '--ignore-gpu-blocklist' "$wrapper"
ok $? chrome.wrapper "$(dpkg-divert --list "$wrapper" 2>/dev/null | head -1)"

bad="$(grep -lE '^Exec=.*/opt/google/chrome' /usr/share/applications/*.desktop "$HOME"/.local/share/applications/*.desktop 2>/dev/null)"
[ -z "$bad" ]; ok $? chrome.launchers "${bad:-no menu entry bypasses the wrapper}"

# A clicked link: run xdg-open inside the desktop session's environment and see which browser
# starts. Reading the default-browser setting is not enough - under XFCE it names a helper
# that hands off through more layers. A throwaway XDG_CONFIG_HOME moves Chrome's default
# profile there, so the dev user's real profile is never touched.
session="$(pgrep -o -u "$USER" xfce4-session)"
xdgtmp="$(mktemp -d /tmp/agentvm-smoke-xdg-XXXXXX)"
# The profile dir never shows on Chrome's command line (it comes from XDG_CONFIG_HOME), so
# the URL carries a marker to find this Chrome by - and to stop exactly it afterwards.
marker="agentvm-smoke-$RANDOM$RANDOM"
(
    for var in DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_DATA_DIRS XDG_SESSION_DESKTOP DESKTOP_SESSION; do
        val="$(tr '\0' '\n' < "/proc/$session/environ" 2>/dev/null | sed -n "s/^$var=//p")"
        [ -n "$val" ] && export "$var=$val"
    done
    export XDG_CONFIG_HOME="$xdgtmp"
    setsid xdg-open "https://example.com/?$marker" >/dev/null 2>&1 &
)
xdgpid=""
for i in $(seq 1 20); do
    sleep 1
    # pgrep -f, not grep over pgrep -af: this script's own command line holds the marker too.
    xdgpid="$(pgrep -f "^/opt/google/chrome/chrome .*$marker" | head -1)"
    [ -n "$xdgpid" ] && break
done
if [ -z "$xdgpid" ]; then
    r FAIL chrome.xdg-open 'xdg-open did not start Google Chrome within 20s'
else
    xdgcmd="$(tr '\0' ' ' < "/proc/$xdgpid/cmdline")"
    echo "$xdgcmd" | grep -q -- '--password-store=basic' && echo "$xdgcmd" | grep -q -- '--ignore-gpu-blocklist'
    ok $? chrome.xdg-open "a clicked link starts: $(echo "$xdgcmd" | head -c 200)"
    kill "$xdgpid" 2>/dev/null
fi
sleep 3; rm -rf "$xdgtmp"

node -e '
    const p = JSON.parse(require("fs").readFileSync("/etc/opt/chrome/policies/managed/claude-in-chrome.json", "utf8"));
    process.exit(p.ExtensionInstallForcelist.some((e) => e.startsWith("fcoeoabgfenejglbffodgkkbkcdhcgfn;")) ? 0 : 1);
' 2>/dev/null
ok $? chrome.extension-policy 'Claude in Chrome force-install policy is valid JSON (ba02431)'

cat > /tmp/agentvm-smoke-chrome.mjs <<'NODE'
// Start Chrome the way a person or an agent does - the wrapper on PATH, no flags of ours
// beyond a throwaway profile and a loopback DevTools port - and record what happens.
import { spawn, execSync } from 'node:child_process';
import { mkdtempSync, existsSync, rmSync } from 'node:fs';

const [expectTz, expectLang] = process.argv.slice(2);
const out = (s, id, d) => console.log(['RESULT', s, id, String(d).replace(/\s+/g, ' ')].join('\t'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sh = (c) => { try { return execSync(c, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }); } catch { return ''; } };

const dir = mkdtempSync('/tmp/agentvm-smoke-profile-');
// A FIXED port, deliberately. --remote-debugging-port=0 (let Chrome pick one, as Puppeteer
// does) makes Chrome 156 report navigator.webdriver === true; a fixed port does not.
const port = 9339;
const chrome = spawn('google-chrome', [`--user-data-dir=${dir}`, `--remote-debugging-port=${port}`,
  '--remote-debugging-address=127.0.0.1', 'https://example.com/'], { detached: true, stdio: 'ignore' });

// Watch the desktop while Chrome starts: either dialog appearing at all is the failure.
const windows = () => sh(`for w in $(xprop -root _NET_CLIENT_LIST | grep -o '0x[0-9a-f]*'); do xprop -id $w WM_CLASS _NET_WM_NAME; done`);
let keyring = false, firstRun = false;
for (let i = 0; i < 15; i++) {
  await sleep(1000);
  const w = windows();
  if (/gcr-prompter|keyring/i.test(w) || sh('pgrep -x gcr-prompter')) keyring = true;
  if (/Terms of Service/i.test(w)) firstRun = true;
}
out(keyring ? 'FAIL' : 'PASS', 'chrome.no-keyring-prompt', keyring ? 'a keyring prompt appeared' : 'no keyring prompt in 15s');
out(firstRun ? 'FAIL' : 'PASS', 'chrome.no-first-run-dialog', firstRun ? 'the first-run terms of service appeared' : 'no first-run dialog in 15s');

const main = sh(`pgrep -af '^/opt/google/chrome/chrome ' | grep -F -- '${dir}' | grep -v -- '--type=' | head -1`);
const flags = ['--password-store=basic', '--no-first-run', '--no-default-browser-check', '--ignore-gpu-blocklist'];
const missing = flags.filter((f) => !main.includes(f));
out(main && !missing.length ? 'PASS' : 'FAIL', 'chrome.started-via-wrapper', main ? (missing.length ? `missing ${missing.join(' ')}` : 'browser process carries the wrapper flags') : 'no Chrome browser process');

try {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === 'page' && t.url.includes('example.com'));
  if (!page) throw new Error('no example.com tab');
  // A fresh profile opens the Claude in Chrome sign-in tab in front of ours. A background tab
  // reports outerHeight === innerHeight, which looks headless, so measure from the front.
  await fetch(`http://127.0.0.1:${port}/json/activate/${page.id}`);
  await sleep(1500);
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  let id = 0;
  const evaluate = (expression) => new Promise((r) => {
    const i = ++id;
    ws.addEventListener('message', function h(e) { const m = JSON.parse(e.data); if (m.id === i) { ws.removeEventListener('message', h); r(m.result?.result?.value); } });
    // Runtime.evaluate without Runtime.enable: enabling the domain is itself detectable.
    ws.send(JSON.stringify({ id: i, method: 'Runtime.evaluate', params: { expression, returnByValue: true } }));
  });
  for (let i = 0; i < 20 && (await evaluate('document.readyState')) !== 'complete'; i++) await sleep(500);
  const v = await evaluate(`(() => {
    const gl = document.createElement('canvas').getContext('webgl');
    const dbg = gl && gl.getExtension('WEBGL_debug_renderer_info');
    return { title: document.title, webdriver: navigator.webdriver, ua: navigator.userAgent,
      languages: navigator.languages, tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
      renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : null,
      visible: document.visibilityState, outer: [outerWidth, outerHeight], inner: [innerWidth, innerHeight] };
  })()`);
  ws.close();
  out(v.title === 'Example Domain' ? 'PASS' : 'FAIL', 'chrome.page-loads', `title "${v.title}"`);
  out(v.webdriver === false && !/Headless/.test(v.ua) ? 'PASS' : 'FAIL', 'chrome.not-automated', `webdriver=${v.webdriver}, ${v.ua}`);
  out(v.tz === expectTz ? 'PASS' : 'FAIL', 'chrome.timezone', `page sees ${v.tz}, host ${expectTz}`);
  // Chrome has no UI language for most regional English variants and falls back to en-GB,
  // as it does on Windows: an en-AU host's own Chrome reports en-GB first too. A locale that
  // never reached the guest shows up as en-US.
  const want = expectLang === 'en-US' || !expectLang.startsWith('en-') ? [expectLang] : [expectLang, 'en-GB'];
  out(want.includes(v.languages[0]) ? 'PASS' : 'FAIL', 'chrome.language', `page sees ${v.languages.join(',')}, host ${expectLang}`);
  // An ordinary window is taller than its page by the tab strip and toolbar; headless is not.
  const framed = v.visible === 'visible' && v.outer[1] > v.inner[1];
  out(framed ? 'PASS' : 'FAIL', 'chrome.window-frame', `${v.visible} tab, window ${v.outer.join('x')}, page ${v.inner.join('x')}`);
  // No WebGL at all, or SwiftShader, both tell a page this is not an ordinary desktop
  // browser; the wrapper's --ignore-gpu-blocklist gets Mesa's llvmpipe instead.
  if (!v.renderer) out('FAIL', 'chrome.webgl', 'no WebGL - a page can tell this is not an ordinary desktop browser');
  else if (/SwiftShader/i.test(v.renderer)) out('FAIL', 'chrome.webgl', `SwiftShader, a headless-browser signature: ${v.renderer}`);
  else out('PASS', 'chrome.webgl', v.renderer);
} catch (e) {
  out('FAIL', 'chrome.page-loads', `could not inspect the page: ${e.message}`);
}

// Chrome fetches the force-installed extension itself on first start; give it 30 s.
const ext = `${dir}/Default/Extensions/fcoeoabgfenejglbffodgkkbkcdhcgfn`;
for (let i = 0; i < 30 && !existsSync(ext); i++) await sleep(1000);
out(existsSync(ext) ? 'PASS' : 'WARN', 'chrome.extension-installed', existsSync(ext) ? 'Claude in Chrome installed into a fresh profile' : 'not downloaded within 30s');

try { process.kill(-chrome.pid, 'SIGTERM'); } catch {}
await sleep(2000);
sh(`pkill -f -- '[a]gentvm-smoke-profile-${dir.split('-').pop()}'`);
await sleep(1000);
rmSync(dir, { recursive: true, force: true });
process.exit(0);
NODE
node /tmp/agentvm-smoke-chrome.mjs "$EXPECT_TZ" "$(echo "$EXPECT_LANG" | sed 's/\.UTF-8$//; s/_/-/')" 2>/dev/null \
    || r FAIL chrome.probe 'the Chrome probe crashed'
rm -f /tmp/agentvm-smoke-chrome.mjs

# ---------------------------------------------------------------- docker ---
# Engine, group, rotating logs, and DNS for musl images through resolved on docker0 (2379fc2).
[ "$(systemctl is-active docker)" = active ]; ok $? docker.service 'docker active'
id -nG | tr ' ' '\n' | grep -qx docker; ok $? docker.group "$USER is in the docker group"
node -e '
    const c = JSON.parse(require("fs").readFileSync("/etc/docker/daemon.json", "utf8"));
    process.exit(c["log-driver"] === "local" && c.bip === "172.17.0.1/16" ? 0 : 1);
' 2>/dev/null
ok $? docker.config 'log-driver local, bip 172.17.0.1/16'
docker compose version >/dev/null 2>&1; ok $? docker.compose "$(docker compose version 2>/dev/null)"
had_alpine="$(docker image ls -q alpine:3 2>/dev/null)"
dns="$(timeout 120 docker run --rm alpine:3 nslookup example.com 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$dns" | grep -q 'Address'; ok $? docker.alpine-dns "$(echo "$dns" | grep -m1 -E 'Address|error|timed out' | head -c 120)"
[ -z "$had_alpine" ] && docker image rm -f alpine:3 >/dev/null 2>&1

# --------------------------------------------------------------- android ---
# adb-bridge binds only the LAN address: on 0.0.0.0 socat forwarded into itself and forked
# without bound, and took 127.0.0.1:5555 from the emulator (9640387).
[ "$(systemctl is-active adb-bridge)" = active ]; bridge_ok=$?
bind="$(ss -ltnpH 'sport = :5555' 2>/dev/null | awk '{print $4}' | tr '\n' ' ')"
socats="$(pgrep -c -x socat)"
[ $bridge_ok -eq 0 ] && ! echo "$bind" | grep -qE '(^| )(0\.0\.0\.0|\*|127\.0\.0\.1):5555' && [ "${socats:-0}" -lt 5 ]
ok $? android.adb-bridge "listening on ${bind:-nothing}, $socats socat process(es)"

# ~/bin/emu must work from shells that never read /etc/profile.d (a0f5b48).
grep -q '/etc/profile.d/android.sh' "$HOME/bin/emu" 2>/dev/null \
    && env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c '. /etc/profile.d/android.sh && command -v emulator && command -v adb' >/dev/null
ok $? android.emu-path '~/bin/emu loads the SDK PATH itself'

[ -d "$HOME/.android/avd/dev.avd/snapshots/golden" ]; ok $? android.snapshot "golden snapshot $(du -sh "$HOME/.android/avd/dev.avd/snapshots/golden" 2>/dev/null | cut -f1)"
[ -c /dev/kvm ] && id -nG | tr ' ' '\n' | grep -qx kvm; ok $? android.kvm '/dev/kvm present, dev in kvm group'
dpkg -s libxcb-cursor0 >/dev/null 2>&1; ok $? android.libxcb-cursor 'libxcb-cursor0 installed (windowed emulator)'

if [ "$INCLUDE_EMULATOR" = 1 ]; then
    . /etc/profile.d/android.sh
    (DISPLAY= "$HOME/bin/emu" -snapshot golden >/tmp/agentvm-smoke-emu.log 2>&1 &)
    timeout 180 adb wait-for-device 2>/dev/null
    booted=""
    for i in $(seq 1 60); do
        booted="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')"
        [ "$booted" = 1 ] && break; sleep 2
    done
    [ "$booted" = 1 ]; ok $? android.emulator-boot "$(adb devices 2>/dev/null | sed -n 2p)"
    adb emu kill >/dev/null 2>&1
else
    r SKIP android.emulator-boot 'pass -IncludeEmulator to boot it'
fi

# ----------------------------------------------------------- claude, tools ---
L() { bash -lc "$1" 2>/dev/null; }
v="$(L 'claude --version')"; [ -n "$v" ]; ok $? claude.cli "${v:-claude not found}"

md="$HOME/.claude/CLAUDE.md"
[ -f "$md" ] && grep -q '~/app' "$md" && ! grep -qiE 'metro|react native' "$md"
ok $? claude.md 'project-agnostic ~/.claude/CLAUDE.md from New-AgentVM.ps1 (85c144b)'

L 'code --list-extensions' | grep -qx anthropic.claude-code; ok $? vscode.claude-extension 'anthropic.claude-code installed'
v="$(L 'gh --version' | head -1)"; [ -n "$v" ]; ok $? tools.gh "${v:-gh not found}"
v="$(L 'node --version')"; [ -n "$v" ]; ok $? tools.node "${v:-node not found}"
v="$(bash -lc 'java -version' 2>&1 | head -1)"; echo "$v" | grep -q version; ok $? tools.java "$v"
pw="$(ls "$HOME/.cache/ms-playwright" 2>/dev/null | tr '\n' ' ')"
echo "$pw" | grep -q chromium && echo "$pw" | grep -q firefox && echo "$pw" | grep -q webkit; ok $? tools.playwright "${pw:-no browsers}"
'@

$hostEpoch = '{0:F3}' -f ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0)
$emu = if ($IncludeEmulator) { '1' } else { '0' }

Write-Host "==> Smoke-testing '$Name' at $Address (host: $expectTz, $expectLang, desktop $expectRes)" -ForegroundColor Cyan
$previous = [Console]::OutputEncoding
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
    $guest = ($suite -replace "`r`n", "`n") |
        # With a UTF-8-with-BOM console input encoding, Windows PowerShell puts U+FEFF in
        # front of piped text; strip it before bash reads the first line.
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$User@$Address" "sed '1s/^\xEF\xBB\xBF//' | bash -s -- '$expectTz' '$expectLang' '$expectRes' '$hostEpoch' '$emu'"
    $sshExit = $LASTEXITCODE
}
finally {
    [Console]::OutputEncoding = $previous
}

$guestResults = @($guest | Where-Object { $_ -like "RESULT`t*" })
if (-not $guestResults) {
    Add-Result FAIL 'ssh' "no results from $User@$Address (ssh exit $sshExit)"
}
foreach ($line in $guestResults) {
    $f = $line -split "`t", 4
    Add-Result $f[1] $f[2] $(if ($f.Count -gt 3) { $f[3] } else { '' })
}
foreach ($line in @($guest | Where-Object { $_ -notlike "RESULT`t*" -and $_ })) { Write-Verbose "guest: $line" }

# ---------------------------------------------------------------- report ---

$colours = @{ PASS = 'Green'; FAIL = 'Red'; WARN = 'Yellow'; SKIP = 'DarkGray' }
foreach ($r in $results) {
    Write-Host ('  {0,-4}  ' -f $r.Status) -ForegroundColor $colours[$r.Status] -NoNewline
    Write-Host ('{0,-28} ' -f $r.Check) -NoNewline
    Write-Host $r.Detail -ForegroundColor DarkGray
}
$count = @{}
foreach ($s in 'PASS', 'FAIL', 'WARN', 'SKIP') { $count[$s] = @($results | Where-Object Status -eq $s).Count }
Write-Host ''
Write-Host ("  {0} passed, {1} failed, {2} warnings, {3} skipped" -f $count.PASS, $count.FAIL, $count.WARN, $count.SKIP) `
    -ForegroundColor $(if ($count.FAIL) { 'Red' } elseif ($count.WARN) { 'Yellow' } else { 'Green' })
exit $count.FAIL
