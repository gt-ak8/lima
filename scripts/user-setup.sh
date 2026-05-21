#!/bin/bash
# Run with -u/-x for visibility, but NOT -e: a single non-fatal failure
# (e.g. OOM during a network installer) must not abort the rest of the
# user-level setup, otherwise zsh/starship/safety-net never get applied
# and the user lands in a half-configured bash on next login.
set -ux

# --- shell ---------------------------------------------------------------
# Set zsh as login shell for current user
sudo usermod -s /usr/bin/zsh "$USER" || true

# --- ssh known_hosts -----------------------------------------------------
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keyscan -t rsa,ecdsa,ed25519 github.com ssh.github.com >>~/.ssh/known_hosts 2>/dev/null || true
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts || true
chmod 600 ~/.ssh/known_hosts

# --- git config ----------------------------------------------------------
# Identity + SSH commit signing. Signing relies on the forwarded SSH agent
# (cc-dev.yaml: forwardAgent: true): the VM never holds the private key on
# disk; ssh-agent on the host signs each commit. The `key::` prefix tells
# git the literal pubkey follows (no on-disk key file lookup needed).
# Values come from cc-dev.yaml `param:` block (sourced from host .env).
git config --global user.name        "${PARAM_GIT_NAME}"
git config --global user.email       "${PARAM_GIT_EMAIL}"
git config --global gpg.format       ssh
git config --global user.signingkey  "${PARAM_GIT_SIGNING_KEY}"
git config --global commit.gpgsign   true
git config --global tag.gpgsign      true

# --- claude code ---------------------------------------------------------
# Best-effort: the native installer can OOM on small VMs; never let it
# abort the rest of the script.
curl -fsSL https://claude.ai/install.sh | bash || echo "WARN: claude install failed, skipping"

# --- zsh config ----------------------------------------------------------
touch ~/.zshrc
grep -q '.local/bin' ~/.zshrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >>~/.zshrc
# TERM fallback: hosts like ghostty/wezterm/kitty forward an exotic $TERM
# the guest does not have terminfo for, breaking backspace, `clear`, colors.
grep -q 'TERM fallback' ~/.zshrc || cat >>~/.zshrc <<'ZRC'
# TERM fallback
[ -n "$TERM" ] && ! infocmp "$TERM" >/dev/null 2>&1 && export TERM=xterm-256color
ZRC
grep -q 'starship init' ~/.zshrc || echo 'eval "$(starship init zsh)"' >>~/.zshrc

# SSH agent socket stabilizer. Zed's remote SSH terminal does NOT inherit
# SSH_AUTH_SOCK from the editor's ssh connection (zed#29438), and tmux
# freezes the value at first attach. Real `ssh lima-cc-dev` logins refresh
# ~/.ssh/agent.sock to point at the live forwarded socket; every other
# shell reads that stable path instead of a stale per-session one.
mkdir -p ~/.ssh && chmod 700 ~/.ssh
grep -q 'agent.sock' ~/.zshrc || cat >>~/.zshrc <<'AGENTSOCK'
if [ -n "$SSH_AUTH_SOCK" ] && [ -S "$SSH_AUTH_SOCK" ] \
   && [ "$SSH_AUTH_SOCK" != "$HOME/.ssh/agent.sock" ]; then
  ln -sf "$SSH_AUTH_SOCK" "$HOME/.ssh/agent.sock"
fi
export SSH_AUTH_SOCK="$HOME/.ssh/agent.sock"
AGENTSOCK

# --- secret service (gnome-keyring, headless) ----------------------------
# keytar-based CLIs (dust, vscode-cli, ...) need a running Secret Service
# on the user's dbus bus. The VM is headless and dev logs in via SSH key,
# so pam_gnome_keyring never gets a password to unlock with. We run
# gnome-keyring-daemon as a user systemd unit and unlock at startup with
# an empty password: same security as a flat on-disk file, but speaks
# org.freedesktop.secrets so keytar clients work.
#
# `--components=secrets` deliberately excludes the ssh-agent component;
# otherwise gnome-keyring would hijack SSH_AUTH_SOCK and break the
# forwarded host SSH agent used for commit signing (see block above).
#
# Bootstrap the `login` keyring file BEFORE starting the unit. `--unlock`
# only opens an existing file; it does NOT create one. On a fresh user
# the file is missing, so the daemon comes up with zero collections and
# keytar clients (dust) hit `Object does not exist at path
# /collection/login` the first time they try to store a token. The
# Secret Service API path that would normally create it (CreateCollection)
# triggers a graphical password prompt which a headless VM has no way to
# answer, so we write the file directly in gnome-keyring's plain-INI
# empty-password format. The daemon picks it up on --unlock and exposes
# it at /org/freedesktop/secrets/collection/login.
mkdir -p "$HOME/.local/share/keyrings"
chmod 700 "$HOME/.local/share/keyrings"
if [ ! -f "$HOME/.local/share/keyrings/login.keyring" ]; then
  NOW=$(date +%s)
  cat >"$HOME/.local/share/keyrings/login.keyring" <<KEYRING
[keyring]
display-name=login
ctime=$NOW
mtime=$NOW
lock-on-idle=false
lock-after=false
KEYRING
  chmod 600 "$HOME/.local/share/keyrings/login.keyring"
  printf 'login' >"$HOME/.local/share/keyrings/default"
  chmod 600 "$HOME/.local/share/keyrings/default"
fi

mkdir -p "$HOME/.config/systemd/user"
cat >"$HOME/.config/systemd/user/gnome-keyring-daemon.service" <<'KEYUNIT'
[Unit]
Description=GNOME Keyring daemon (secrets only, headless unlock)

[Service]
Type=simple
ExecStart=/bin/sh -c 'printf "" | exec /usr/bin/gnome-keyring-daemon --foreground --components=secrets --unlock'
Restart=on-failure

[Install]
WantedBy=default.target
KEYUNIT

# enable-linger ran in system-deps.sh, so user@1000.service should already
# be up at this point. `|| true` keeps provisioning resilient if the user
# manager isn't reachable on first boot: the symlinks land in the WantedBy
# dir anyway and activate on next SSH login.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user daemon-reload || true
systemctl --user enable --now gnome-keyring-daemon.service || true

# --- bash safety net -----------------------------------------------------
# `limactl shell` and even plain ssh can land in bash (e.g. when a stale
# ssh ControlMaster cached the pre-chsh shell). Bash login shells read
# ~/.bash_profile (or ~/.profile) but NOT ~/.bashrc, and Lima rewrites
# ~/.profile to a PATH-only stub that does not source ~/.bashrc, so the
# jump must live in ~/.bash_profile.
touch ~/.bash_profile
grep -q 'exec zsh' ~/.bash_profile || cat >>~/.bash_profile <<'PROF'
[ -f ~/.profile ] && . ~/.profile
[ -f ~/.bashrc ]  && . ~/.bashrc
# TERM fallback (see ~/.zshrc for rationale)
[ -n "$TERM" ] && ! infocmp "$TERM" >/dev/null 2>&1 && export TERM=xterm-256color
case $- in *i*) [ -z "$ZSH_VERSION" ] && exec zsh -l ;; esac
PROF

# =========================================================================
# Tech stack — keep this as the LAST section.
#
# We do NOT install the tech stack synchronously from cloud-init: combined
# downloads (java + gradle + maven + node + bun) routinely exceed lima's
# ~10 minute boot-script timeout, after which `limactl start` fails with
# `did not receive an event with the "running" status`.
#
# Strategy: stage the work as ~/.install-tech-stack.sh and launch it as a
# *system* transient unit (`systemd-run --uid=dev`) so it outlives the
# cloud-init session.scope (which is otherwise GC'd when provisioning
# returns, killing any backgrounded children regardless of nohup/setsid).
#
# Watch progress:  tail -f ~/.tech-stack.log
# Watch unit:      sudo journalctl -u lima-tech-stack -f
# Done marker:     ~/.tech-stack.done
# Add new tools below; keep the staging contract.
# =========================================================================

# Wire shell rc lines now so `source ~/.zshrc` picks tools up the moment
# the async installer finishes.
grep -q 'BUN_INSTALL' ~/.zshrc || cat >>~/.zshrc <<'BUNRC'
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
BUNRC
grep -q 'PNPM_HOME' ~/.zshrc || cat >>~/.zshrc <<'PNPMRC'
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in *":$PNPM_HOME:"*) ;; *) export PATH="$PNPM_HOME:$PATH" ;; esac
PNPMRC
grep -q 'NVM_DIR' ~/.zshrc || cat >>~/.zshrc <<'NVMRC'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
NVMRC
grep -q 'SDKMAN_DIR' ~/.zshrc || cat >>~/.zshrc <<'SDKRC'
export SDKMAN_DIR="$HOME/.sdkman"
[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && . "$SDKMAN_DIR/bin/sdkman-init.sh"
SDKRC
grep -q 'cargo/env' ~/.zshrc || cat >>~/.zshrc <<'CARGORC'
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
CARGORC

# Stage the installer.
cat >"$HOME/.install-tech-stack.sh" <<'TECH'
#!/bin/bash
set -ux
exec >>"$HOME/.tech-stack.log" 2>&1
echo "=== tech-stack started: $(date -uIs) ==="

# bun
if [ ! -x "$HOME/.bun/bin/bun" ]; then
  curl -fsSL https://bun.sh/install | bash || echo "WARN: bun install failed"
fi

# pnpm (standalone install; sets PNPM_HOME=$HOME/.local/share/pnpm)
if [ ! -x "$HOME/.local/share/pnpm/pnpm" ]; then
  curl -fsSL https://get.pnpm.io/install.sh | ENV="$HOME/.zshrc" SHELL="$(command -v zsh)" bash \
    || echo "WARN: pnpm install failed"
fi

# nvm + node LTS
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash \
    || echo "WARN: nvm install failed"
fi
if [ -s "$NVM_DIR/nvm.sh" ]; then
  set +u
  . "$NVM_DIR/nvm.sh"
  nvm install --lts || echo "WARN: node LTS install failed"
  nvm alias default 'lts/*' || true
  # Global npm CLIs that need node. Installed under the active nvm prefix
  # so they follow node LTS upgrades. dust uses gnome-keyring set up in
  # system-deps.sh / the user systemd unit above; copilot uses gh auth.
  if command -v npm >/dev/null 2>&1; then
    npm install -g @dust-tt/dust-cli || echo "WARN: dust-cli install failed"
    npm install -g @github/copilot   || echo "WARN: copilot cli install failed"
  fi
  set -u
fi

# sdkman + java 25 + gradle latest + maven 3
export SDKMAN_DIR="$HOME/.sdkman"
if [ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  curl -s "https://get.sdkman.io?rcupdate=false" | bash \
    || echo "WARN: sdkman install failed"
fi
if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
  mkdir -p "$SDKMAN_DIR/etc"
  grep -q '^sdkman_auto_answer=' "$SDKMAN_DIR/etc/config" 2>/dev/null \
    || echo 'sdkman_auto_answer=true' >>"$SDKMAN_DIR/etc/config"
  set +u
  . "$SDKMAN_DIR/bin/sdkman-init.sh"
  JAVA_ID=$(sdk list java 2>/dev/null \
    | grep -oE '25(\.[0-9]+){0,3}-tem\b' | sort -V | tail -1)
  sdk install java "${JAVA_ID:-25-tem}" </dev/null \
    || echo "WARN: java 25 install failed"
  sdk install gradle </dev/null \
    || echo "WARN: gradle install failed"
  MAVEN_ID=$(sdk list maven 2>/dev/null \
    | grep -oE '\b3\.[0-9]+\.[0-9]+\b' | sort -V | tail -1)
  sdk install maven "${MAVEN_ID:-3.9.11}" </dev/null \
    || echo "WARN: maven install failed"
  set -u
fi

# rustup + stable toolchain (cargo, rustc, rustup)
if [ ! -x "$HOME/.cargo/bin/rustup" ]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --no-modify-path \
    || echo "WARN: rustup install failed"
fi
if [ -f "$HOME/.cargo/env" ]; then
  set +u
  . "$HOME/.cargo/env"
  set -u
fi

# worktrunk (git worktree manager for parallel AI agents). Built from
# crates.io via cargo; binary is `wt`. Skipped if already installed.
if ! command -v wt >/dev/null 2>&1 && [ -x "$HOME/.cargo/bin/cargo" ]; then
  "$HOME/.cargo/bin/cargo" install worktrunk || echo "WARN: worktrunk install failed"
fi

# just (prebuilt binary, skips the multi-minute cargo build).
# just.systems/install.sh drops a single static binary into --to. We use
# ~/.local/bin which is already on PATH from the zshrc wiring above.
if ! command -v just >/dev/null 2>&1; then
  mkdir -p "$HOME/.local/bin"
  curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
    | bash -s -- --to "$HOME/.local/bin" \
    || echo "WARN: just install failed"
fi

# uv (Python package/project manager, prebuilt binary). Installer drops
# uv/uvx into ~/.local/bin (already on PATH). --no-modify-path keeps the
# installer from appending its own PATH line to ~/.zshrc.
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR="$HOME/.local/bin" INSTALLER_NO_MODIFY_PATH=1 sh \
    || echo "WARN: uv install failed"
fi

echo "=== tech-stack finished: $(date -uIs) ==="
touch "$HOME/.tech-stack.done"
TECH
chmod +x "$HOME/.install-tech-stack.sh"

# Launch detached as a system transient unit so it outlives the cloud-init
# session.scope. Falls back to nohup+setsid if systemd-run is unavailable
# (extremely unlikely on Ubuntu Noble, but keeps the script portable).
if command -v systemd-run >/dev/null 2>&1; then
  sudo systemd-run \
    --collect --no-block \
    --uid=dev --gid=dev \
    --setenv=HOME=/home/dev \
    --setenv=USER=dev \
    --setenv=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --unit=lima-tech-stack \
    --description="Lima cc-dev tech stack installer" \
    /bin/bash /home/dev/.install-tech-stack.sh \
    || nohup setsid /bin/bash "$HOME/.install-tech-stack.sh" </dev/null >/dev/null 2>&1 &
else
  nohup setsid /bin/bash "$HOME/.install-tech-stack.sh" </dev/null >/dev/null 2>&1 &
fi
