#!/usr/bin/env bash
# Node LTS, JDK 17, a C/C++ toolchain and watchman - the React Native build toolchain.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

: "${NODE_MAJOR:=22}"
# Empty means "resolve the newest release that actually ships a linux build" - see below.
: "${WATCHMAN_VERSION:=}"

echo "==> OpenJDK 17 (Gradle's supported JDK for current AGP)"
sudo apt-get install -y openjdk-17-jdk

echo "==> JAVA_HOME (system-wide)"
# Gradle finds a JDK on PATH, but the React Native and Capacitor CLIs read JAVA_HOME
# directly and print "JAVA_HOME is not set" rather than falling back, so set it here
# instead of leaving every project to discover the omission.
sudo tee /etc/profile.d/java.sh >/dev/null <<'JAVA'
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
JAVA
sudo chmod 644 /etc/profile.d/java.sh

echo "==> C/C++ toolchain"
# Not optional despite nothing here naming it. node-gyp compiles the native halves of
# ordinary npm dependencies, and React Native's own Android build runs CMake + Ninja to
# build Hermes and the JSI native modules. Without these, "npm install" and the first
# ./gradlew assembleDebug fail on a missing compiler, deep inside build output that does
# not obviously say so.
sudo apt-get install -y     build-essential     cmake     ninja-build     pkg-config     python3-dev

echo "==> Node ${NODE_MAJOR}.x from NodeSource"
curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
sudo apt-get install -y nodejs

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

    sudo apt-get install -y libssl-dev || return 1
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
echo "watchman: ${watchman_status}"

echo "==> 20-node-java.sh done"
