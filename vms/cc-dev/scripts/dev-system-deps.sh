#!/bin/bash
# cc-dev system-mode add-ons (runs AFTER base/provision.sh).
# Installs gnome-keyring / dbus user session bits required by keytar-based
# CLIs (dust, vscode-cli, ...) installed in dev-user-setup.sh.
set -eux
export DEBIAN_FRONTEND=noninteractive

apt-get install -y \
  gnome-keyring \
  libsecret-1-0 \
  dbus-user-session

# Linger keeps user@1000.service (and its dbus user bus) alive across SSH
# sessions. Required so the gnome-keyring user unit installed by
# dev-user-setup.sh has a live user manager to register against, and so
# keytar-based CLIs find a running Secret Service on every new SSH login
# rather than only inside an interactive session.
loginctl enable-linger dev
