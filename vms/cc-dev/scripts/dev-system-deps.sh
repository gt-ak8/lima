#!/bin/bash
# cc-dev system-mode add-ons (runs AFTER base/provision.sh).
set -eux
export DEBIAN_FRONTEND=noninteractive

# gnome-keyring provides org.freedesktop.secrets (the D-Bus Secret Service)
# that keytar-based CLIs (e.g. `dust`) need to store/read tokens. Without it
# any keyring access aborts with "org.freedesktop.secrets was not provided by
# any .service files". The daemon is started + unlocked per-login from
# ~/.zprofile (see dev-user-setup.sh); this headless VM has no desktop session
# to do it.
if ! command -v gnome-keyring-daemon >/dev/null 2>&1; then
  apt-get install -y gnome-keyring
fi

# Docker CE from Docker's official apt repo (Debian's docker.io is older and
# ships without the compose v2 / buildx plugins).
# Ref: https://docs.docker.com/engine/install/debian/
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update
fi

if ! command -v docker >/dev/null 2>&1; then
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
fi

# Let `dev` use the docker socket without sudo. Lima's boot-time SSH master
# was authenticated before this group existed, and any host-side ControlMaster
# multiplexes over it, so every later session inherits stale supplementary
# groups (no docker) until that master dies. Bounce sshd well after Lima's
# provisioning returns so the next `vci` re-auths and picks up docker.
if ! id -nG dev | grep -qw docker; then
  usermod -aG docker dev
  systemd-run --on-active=45s --collect \
    --unit=lima-sshd-bounce \
    systemctl restart ssh
fi
