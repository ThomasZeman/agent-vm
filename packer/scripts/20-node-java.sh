#!/usr/bin/env bash
# Node LTS, JDKs via SDKMAN, a C/C++ toolchain and watchman - the React Native build toolchain.

set -euo pipefail

# sudo runs with env_reset, so an exported DEBIAN_FRONTEND never reaches the apt-get on the
# other side of it - which is what fills the build log with "debconf: unable to initialize
# frontend: Dialog" and two more lines walking down to Teletype. Passing the settings as sudo
# arguments is the form that survives. NEEDRESTART_SUSPEND silences the apt hook that lists
# deferred restarts and outdated sessions: accurate, and meaningless for a machine that is
# about to be shut down and imaged.
apt_get() {
    sudo DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 apt-get "$@"
}

: "${NODE_MAJOR:=22}"
# Empty means "resolve the newest release that actually ships a linux build" - see below.
: "${WATCHMAN_VERSION:=}"
# JDK majors to install, and the FIRST one is the default. 21 leads because
# @capacitor/android compiles its own sources at Java 21 from Capacitor 7 on, so an image
# without it fails those builds outright. 17 follows for projects whose Gradle predates 8.5
# and so cannot run on a 21 JDK at all; anything newer compiles a 17 target on the 21 JDK.
: "${JDK_MAJORS:=21 17}"
: "${JDK_VENDOR:=tem}"

echo "==> SDKMAN"
# SDKMAN rather than the archive's openjdk-*-jdk packages: JDK majors move faster than
# Ubuntu does, and this puts switching one in the hands of whoever is using the VM - a
# `sdk install java 25-tem` in the guest, no image rebuild, no root.
apt_get install -y zip unzip

export SDKMAN_DIR="$HOME/.sdkman"
curl -fsSL "https://get.sdkman.io?rcupdate=true" | bash

# Checked before -e comes off below, because from that point on a missing init script would
# turn every `sdk` call into "command not found" and the build would carry on regardless.
[ -r "$SDKMAN_DIR/bin/sdkman-init.sh" ] \
    || { echo "ERROR: SDKMAN did not install into ${SDKMAN_DIR}" >&2; exit 1; }

# sdkman-init.sh reads variables it has not set yet and ends on statements that return
# non-zero, so `set -euo pipefail` kills this script the moment it is sourced. The SDKMAN
# section runs with -e and -u relaxed and turns them back on at the end of it; the installs
# below check their own exit status instead.
set +eu
# shellcheck disable=SC1091
source "$SDKMAN_DIR/bin/sdkman-init.sh"

# Without this, `sdk install` stops to ask whether the new JDK should become the default
# and waits on an answer that is never coming - the provisioner has no terminal.
sed -i 's/^sdkman_auto_answer=.*/sdkman_auto_answer=true/' "$SDKMAN_DIR/etc/config"

echo "==> JDKs (${JDK_MAJORS}; vendor ${JDK_VENDOR})"
# SDKMAN identifiers carry the full version - "21.0.9-tem", not "21" - so pinning them here
# would go stale the next time the vendor ships a patch. Resolve the newest identifier per
# major out of `sdk list java`.
#
# Identifiers may carry a "+build" suffix ("21.0.12+1.1-tem"), so the pattern takes "+" as
# well as "." between the numbers. Matching dots only, grep -o pulled "1.1-tem" out of that
# one, which starts with no major at all, and the build failed on "no tem build of Java 21"
# while 17.0.20-tem resolved fine. Sorted by version rather than trusting the listing order.
latest_jdk() {
    sdk list java 2>/dev/null \
        | grep -oE "[0-9]+([.+][0-9]+)*-${JDK_VENDOR}\b" \
        | grep -E "^${1}\." \
        | sort -Vr \
        | head -n1
}

default_jdk=""
for major in $JDK_MAJORS; do
    jdk_id="$(latest_jdk "$major")"
    if [ -z "$jdk_id" ]; then
        echo "ERROR: no ${JDK_VENDOR} build of Java ${major} in 'sdk list java'" >&2
        exit 1
    fi
    echo "    ${jdk_id}"
    sdk install java "$jdk_id" || { echo "ERROR: sdk install java ${jdk_id} failed" >&2; exit 1; }
    [ -n "$default_jdk" ] || default_jdk="$jdk_id"
done

sdk default java "$default_jdk" || { echo "ERROR: sdk default java ${default_jdk} failed" >&2; exit 1; }

# The downloaded tarballs are dead weight in an image that is about to be compacted.
rm -rf "${SDKMAN_DIR:?}/archives/"* "${SDKMAN_DIR:?}/tmp/"*

echo "==> JAVA_HOME and a java for shells SDKMAN never reaches"
# SDKMAN is a shell function in a per-user directory, hooked into ~/.bashrc. That covers
# interactive and login shells and nothing else - and "nothing else" here includes the
# Packer provisioners that follow this script, systemd units, and `ssh vm '...'` command
# invocations - none of which read .bashrc, and none of which would otherwise find a java
# on PATH at all, since there is no longer one in /usr/bin.
#
# So: export the candidate path for shells that read profile.d (Gradle would find a JDK on
# PATH anyway, but the React Native and Capacitor CLIs read JAVA_HOME directly and print
# "JAVA_HOME is not set" rather than falling back), and symlink the tools that matter into
# /usr/local/bin, which IS on the default non-interactive PATH, for the rest. Both go
# through SDKMAN's "current" symlink, so `sdk default java` still decides the version.
sudo tee /etc/profile.d/java.sh >/dev/null <<PROFILE
export SDKMAN_DIR=${SDKMAN_DIR}
export JAVA_HOME=${SDKMAN_DIR}/candidates/java/current
export PATH="\$JAVA_HOME/bin:\$PATH"
PROFILE
sudo chmod 644 /etc/profile.d/java.sh

for tool in java javac jar jarsigner keytool; do
    sudo ln -sfn "${SDKMAN_DIR}/candidates/java/current/bin/${tool}" "/usr/local/bin/${tool}"
done

set -eu

echo "==> C/C++ toolchain"
# Not optional despite nothing here naming it. node-gyp compiles the native halves of
# ordinary npm dependencies, and React Native's own Android build runs CMake + Ninja to
# build Hermes and the JSI native modules. Without these, "npm install" and the first
# ./gradlew assembleDebug fail on a missing compiler, deep inside build output that does
# not obviously say so.
apt_get install -y     build-essential     cmake     ninja-build     pkg-config     python3-dev

echo "==> Node ${NODE_MAJOR}.x from NodeSource"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
apt_get install -y nodejs

echo "==> watchman (optional)"
# Not packaged for Ubuntu, so this takes the prebuilt release zip - but that asset is
# published only on *some* tags. The pin this used to carry (v2024.11.11.00) no longer has
# one, and the resulting 404 killed the build 18 minutes in, after everything else had
# already installed. Nothing in the image needs watchman: it is a file-watching daemon that
# Metro uses if present and otherwise replaces with its own crawler - slower on a large
# tree, identical in behaviour. So resolve a tag that really has the asset, and treat any
# failure as a warning rather than a failed image.
install_watchman() {
    local url zip dir
    url="${WATCHMAN_VERSION:+https://github.com/facebook/watchman/releases/download/${WATCHMAN_VERSION}/watchman-${WATCHMAN_VERSION}-linux.zip}"
    if [ -z "$url" ]; then
        echo "    resolving the newest release that ships a linux build"
        url="$(curl -fsSL 'https://api.github.com/repos/facebook/watchman/releases?per_page=30' \
               | grep -o 'https://[^"]*/watchman-v[^"]*-linux\.zip' | head -n1)" || true
    fi
    if [ -z "$url" ]; then
        echo "    no linux build found in the last 30 releases" >&2
        return 1
    fi

    echo "    ${url##*/}"
    zip=/tmp/watchman.zip
    curl -fsSL -o "$zip" "$url" || { echo "    download failed: $url" >&2; return 1; }

    apt_get install -y libssl-dev || return 1
    rm -rf /tmp/watchman && mkdir -p /tmp/watchman
    unzip -q "$zip" -d /tmp/watchman || return 1
    dir="$(find /tmp/watchman -maxdepth 1 -mindepth 1 -type d | head -n1)"
    [ -n "$dir" ] || return 1
    sudo cp -a "${dir}/bin/"* /usr/local/bin/ || return 1
    sudo cp -a "${dir}/lib/"* /usr/local/lib/ || return 1
    sudo mkdir -p /usr/local/var/run/watchman
    sudo chown -R "$USER:$USER" /usr/local/var/run/watchman
    sudo chmod 2777 /usr/local/var/run/watchman
}

if install_watchman; then
    watchman_status="$(watchman --version 2>&1 | head -n1)"
else
    watchman_status="not installed - Metro will use its own crawler (slower on large trees,
             otherwise equivalent). Nothing else in the image depends on it."
fi
rm -rf /tmp/watchman /tmp/watchman.zip

echo "==> versions"
node --version
npm --version
java -version 2>&1 | head -n1
echo "JDKs: $(ls "$SDKMAN_DIR/candidates/java" | grep -v '^current$' | tr '\n' ' ')"
echo "watchman: ${watchman_status}"

echo "==> 20-node-java.sh done"
