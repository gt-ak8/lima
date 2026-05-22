#!/bin/bash
# cc-dev user-mode add-ons (runs AFTER base/user-provision.sh).
# Installs Claude Code, sets up the headless gnome-keyring user unit, wires
# tech-stack rc lines, then stages the async tech-stack installer.
#
# NOT -e: a single failure (e.g. claude OOM, npm hiccup) must not abort the
# rest of the setup.
set -ux

# --- claude code ---------------------------------------------------------
# Best-effort: the native installer can OOM on small VMs; never let it
# abort the rest of the script. Skip if already installed (provision
# scripts re-run on every `limactl start`).
if ! command -v claude >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/claude" ]; then
  curl -fsSL https://claude.ai/install.sh | bash || echo "WARN: claude install failed, skipping"
fi

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
# forwarded host SSH agent used for commit signing.
#
# Bootstrap the `login` keyring file BEFORE starting the unit. `--unlock`
# only opens an existing file; it does NOT create one. On a fresh user
# the file is missing, so the daemon comes up with zero collections and
# keytar clients (dust) hit `Object does not exist at path
# /collection/login` the first time they try to store a token. The
# Secret Service API path that would normally create it (CreateCollection)
# triggers a graphical password prompt which a headless VM has no way to
# answer, so we write the file directly in gnome-keyring's plain-INI
# empty-password format.
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

# enable-linger ran in dev-system-deps.sh, so user@1000.service should
# already be up. `|| true` keeps provisioning resilient if the user
# manager isn't reachable on first boot.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
systemctl --user daemon-reload || true
systemctl --user enable --now gnome-keyring-daemon.service || true

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
  if [ -z "$(ls "$NVM_DIR/versions/node" 2>/dev/null)" ]; then
    nvm install --lts || echo "WARN: node LTS install failed"
    nvm alias default 'lts/*' || true
  fi
  # Global npm CLIs that need node. Installed under the active nvm prefix
  # so they follow node LTS upgrades. dust uses gnome-keyring set up above;
  # copilot uses gh auth.
  if command -v npm >/dev/null 2>&1; then
    command -v dust    >/dev/null 2>&1 || npm install -g @dust-tt/dust-cli || echo "WARN: dust-cli install failed"
    command -v copilot >/dev/null 2>&1 || npm install -g @github/copilot   || echo "WARN: copilot cli install failed"
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
  if [ ! -d "$SDKMAN_DIR/candidates/java/current" ]; then
    JAVA_ID=$(sdk list java 2>/dev/null \
      | grep -oE '25(\.[0-9]+){0,3}-tem\b' | sort -V | tail -1)
    sdk install java "${JAVA_ID:-25-tem}" </dev/null \
      || echo "WARN: java 25 install failed"
  fi
  if [ ! -d "$SDKMAN_DIR/candidates/gradle/current" ]; then
    sdk install gradle </dev/null \
      || echo "WARN: gradle install failed"
  fi
  if [ ! -d "$SDKMAN_DIR/candidates/maven/current" ]; then
    MAVEN_ID=$(sdk list maven 2>/dev/null \
      | grep -oE '\b3\.[0-9]+\.[0-9]+\b' | sort -V | tail -1)
    sdk install maven "${MAVEN_ID:-3.9.11}" </dev/null \
      || echo "WARN: maven install failed"
  fi
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
