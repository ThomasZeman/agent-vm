#!/usr/bin/env bash
# Node LTS, JDK 21 + 17, a C/C++ toolchain and watchman - the React Native build toolchain.

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

echo "==> OpenJDK 21 and 17"
# 21 is the default: @capacitor/android compiles its own sources at Java 21 from Capacitor 7
# on, so a 17-only image fails those builds outright. 17 stays alongside it for projects
# whose Gradle predates 8.5 and so cannot run on a 21 JDK at all; they pick it by overriding
# JAVA_HOME. Anything newer builds a 17 target fine on the 21 JDK via --release.
apt_get install -y openjdk-21-jdk openjdk-17-jdk

echo "==> JAVA_HOME (system-wide)"
# Gradle finds a JDK on PATH, but the React Native and Capacitor CLIs read JAVA_HOME
# directly and print "JAVA_HOME is not set" rather than falling back, so set it here
# instead of leaving every project to discover the omission.
sudo tee /etc/profile.d/java.sh >/dev/null <<'JAVA'
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
JAVA
sudo chmod 644 /etc/profile.d/java.sh

# Both packages register update-alternatives entries, and the winner is decided by package
# priority - which is not something to leave to chance when it decides what `java` on PATH
# means. Point the alternatives at 21 so PATH and JAVA_HOME agree.
for tool in java javac; do
    sudo update-alternatives --set "$tool" "/usr/lib/jvm/java-21-openjdk-amd64/bin/$tool"
done

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
echo "also installed: $(ls -d /usr/lib/jvm/java-1?-openjdk-amd64 | tr '\n' ' ')"
echo "watchman: ${watchman_status}"

echo "==> 20-node-java.sh done"
