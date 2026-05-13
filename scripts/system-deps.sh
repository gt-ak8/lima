#!/bin/bash
set -eux
export DEBIAN_FRONTEND=noninteractive

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
  jq

# Ubuntu ships fd as `fdfind` to avoid a name clash; expose it as `fd`.
ln -sf /usr/bin/fdfind /usr/local/bin/fd

# Set zsh as default shell for dev user
chsh -s /usr/bin/zsh dev

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

# Install gh CLI from the official GitHub apt repo.
# Ref: https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian
# Uses curl (already installed above) instead of wget for the keyring.
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  >/etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y gh
