#!/usr/bin/env bash
# Docker Engine from Docker's own apt repository, with the buildx and compose plugins.
#
# The agent uses it to run services a project needs (a database, a queue) and to try things
# in a throwaway container instead of on the VM itself. Containers only need the guest's
# kernel, not nested virtualization; this works in any VM from the image.
#
# Docker's repository, not Ubuntu's docker.io: docker.io lags behind and ships no compose v2
# plugin, so `docker compose` would not exist.

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

echo "==> Docker Engine (Docker apt repository)"
apt_get install -y ca-certificates curl
# Keyring + signed-by, as for VS Code in 25-ide-browser.sh, not the deprecated apt-key.
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
# shellcheck disable=SC1091
codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
apt_get update
apt_get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> container DNS through systemd-resolved"
# By default Docker copies the upstream servers (the router) into each container. Home routers
# commonly mishandle the A and AAAA queries that musl (Alpine) sends in parallel from one
# socket: on my network every lookup from an Alpine container timed out, node:22-alpine's
# fetch failed with EAI_AGAIN, while glibc images and the VM itself resolved fine. The VM never
# notices because systemd-resolved sits between it and the router.
#
# So containers use resolved too: it also listens on the docker0 address, and the daemon hands
# that address to containers. User-defined networks (compose) go through Docker's embedded DNS,
# which forwards to the same address from the host. Names on the LAN keep working, unlike with
# a hardcoded public resolver. resolved binds the address with IP_FREEBIND, so it starts before
# docker0 exists; `bip` pins docker0 to it instead of letting Docker pick a free subnet.
sudo install -m 0755 -d /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSStubListenerExtra=172.17.0.1\n' \
    | sudo tee /etc/systemd/resolved.conf.d/docker.conf >/dev/null
sudo systemctl restart systemd-resolved.service

echo "==> daemon settings"
# Log rotation: the default json-file driver never rotates, and an agent that leaves a chatty
# container running for hours fills the VM's disk with one log file. The "local" driver is
# compact and rotates (5 x 20MB per container by default); `docker logs` still works.
sudo install -m 0755 -d /etc/docker
echo '{ "log-driver": "local", "bip": "172.17.0.1/16", "dns": ["172.17.0.1"] }' \
    | sudo tee /etc/docker/daemon.json >/dev/null

# The package enables both units; explicit, so a changed packaging default cannot leave a VM
# without a daemon after boot.
sudo systemctl enable docker.service containerd.service
sudo systemctl restart docker.service

echo "==> dev in the docker group"
# So the agent runs `docker` without sudo. It is root-equivalent, which changes nothing here:
# dev already has passwordless sudo. Takes effect at the next login, i.e. in every VM, but
# not in this build session - hence sudo below.
sudo usermod -aG docker "$USER"

echo "==> smoke test"
# Fails the build here, not in the first VM: pulls, runs a shell in Alpine, and resolves a name
# with musl's resolver, the case the DNS setup above exists for. The image is removed again:
# the golden image carries no container images, each VM pulls what its project needs.
sudo docker run --rm alpine sh -c 'nslookup example.com >/dev/null && echo "    alpine: sh runs, DNS resolves"' \
    || { echo "    'docker run alpine' failed, or the container could not resolve example.com" >&2; exit 1; }
sudo docker system prune -af >/dev/null
docker --version
docker compose version

echo "==> 27-docker.sh done"
