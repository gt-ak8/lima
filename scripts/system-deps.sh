#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive

# Register the gh CLI apt repo upfront so a single apt-get update covers both
# Debian main and gh (avoids the two-update / two-install dance).
# Debian cloud images ship curl + ca-certificates pre-installed (cloud-init
# depends on them), so we can fetch the keyring before apt install.
# Ref: https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  >/etc/apt/sources.list.d/github-cli.list

apt-get update
apt-get install -y \
  curl \
  ca-certificates \
  git \
  zsh \
  unzip \
  zip \
  ripgrep \
  fd-find \
  build-essential \
  jq \
  gh

# Debian (like Ubuntu) ships fd as `fdfind` to avoid a name clash; expose it as `fd`.
ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Set zsh as default shell for dev user
chsh -s /usr/bin/zsh dev

# Trim boot-time services we never use. Cuts seconds off every restart and
# avoids periodic apt/man-db churn that competes with shell startup.
# `|| true` per unit so a missing one (varies by image build) never aborts.
for unit in \
  apt-daily.timer \
  apt-daily-upgrade.timer \
  man-db.timer \
  motd-news.timer \
  motd-news.service \
  systemd-networkd-wait-online.service \
  NetworkManager-wait-online.service \
  unattended-upgrades.service \
  fwupd.service \
  fwupd-refresh.timer ; do
  systemctl disable --now "$unit" 2>/dev/null || true
  systemctl mask "$unit" 2>/dev/null || true
done

# Swap: belt-and-suspenders against installer memory spikes (claude native
# installer alone allocates ~3.5 GiB RSS). Skipped if already present.
if ! swapon --show | grep -q .; then
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

# Install starship (system-wide binary)
curl -fsSL https://starship.rs/install.sh | sh -s -- --yes
