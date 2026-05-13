# cc-dev — Lima VM for Claude Code

## Overview

Ubuntu LTS Lima VM preconfigured for [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) with an async tech-stack installer (bun, node/nvm, java/gradle/maven via sdkman, rust + just) and a synced `~/.claude/` config.

Key design points:
- 8 GiB RAM + 4 GiB swap (Claude native installer allocates ~3.5 GiB RSS; 4 GiB OOM-killed it).
- virtiofs mount of a host project dir at the same absolute path inside the guest (so paths resolve identically on both sides).
- SSH host port pinned to `2222` so `ssh lima-cc-dev` stays stable across restarts.
- Tech-stack install staged as a transient systemd unit (`lima-tech-stack`) to outlive cloud-init's ~10 min boot-script timeout.

Refs: [Lima](https://lima-vm.io/) · [Lima provisioning](https://lima-vm.io/docs/config/provision/) · [Claude Code settings](https://docs.claude.com/en/docs/claude-code/settings).

## Prerequisites

- `lima` installed: [install guide](https://lima-vm.io/docs/installation/).
- A host directory to mount into the VM. Edit both `mounts[0].location` and `mounts[0].mountPoint` in `cc-dev.yaml` to your host path (kept identical so the guest sees the same absolute path).

## Directory layout

```
.
├── cc-dev.yaml                    # Lima VM spec
├── scripts/
│   ├── system-deps.sh             # root provisioning
│   ├── user-setup.sh              # user provisioning + async tech-stack
│   └── sync-claude-config.sh      # push claude/* into VM ~/.claude/
└── claude/
    ├── CLAUDE.md                  # global instructions inside the VM
    ├── settings.json              # Claude Code settings
    └── statusline-command.sh      # custom statusline
```

## Walkthrough

### `cc-dev.yaml`

VM spec: base image, memory, user, SSH, mount, provision hooks. Update `mounts[0].location` to your host path before first start.

```yaml
base:
  - template:ubuntu-lts

# Sized for the claude native installer, which allocates ~3.5 GiB RSS
# (Bun mmaps a large heap). 4 GiB + 0 swap OOM-killed it during provisioning.
memory: "8GiB"

user:
  name: "dev"
  home: "/home/dev"

ssh:
  # Pin the host port forwarded to the guest's sshd:22.
  # Without this, Lima picks a random free port on each start, breaking
  # `ssh lima-cc-dev` (the lima-managed ssh.config is regenerated, but any
  # cached known_hosts entries / scripted ports go stale).
  localPort: 2222
  forwardAgent: true
  loadDotSSHPubKeys: false

mounts:
  # Same path on host and guest so absolute paths resolve identically.
  - location: "<HOST_PROJECTS_DIR>"   # e.g. /Users/<you>/dev/projects
    mountPoint: "<HOST_PROJECTS_DIR>" # keep identical to `location`
    writable: true
mountType: "virtiofs"

provision:
  - mode: system
    file: ./scripts/system-deps.sh
  - mode: user
    file: ./scripts/user-setup.sh
```

### `scripts/system-deps.sh`

Root provisioning: apt deps, expose `fdfind` as `fd`, set zsh as default for `dev`, allocate 4 GiB swap, install [starship](https://starship.rs/).

```bash
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
```

### `scripts/user-setup.sh`

User provisioning: ssh known_hosts seed, [Claude Code install](https://docs.claude.com/en/docs/claude-code/setup), zshrc/bash_profile wiring, then stages an async tech-stack installer as a transient systemd unit. Watch with `tail -f ~/.tech-stack.log`; done marker is `~/.tech-stack.done`.

```bash
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

# just (compiled via cargo; cargo must already be on PATH from rustup)
if command -v cargo >/dev/null 2>&1 && ! command -v just >/dev/null 2>&1; then
  cargo install just || echo "WARN: just install failed"
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
```

### `claude/CLAUDE.md`

Global Claude Code instructions inside the VM. Synced to `~/.claude/CLAUDE.md`.

```markdown
When reporting information to me, be extremely concise and sacrifice grammar for the sake of concision.
Use English only unless explicitely asked or stated.
Never use em dash (—) or double hyphen (--).
For exploration: use `fd` for file/path discovery and `rg` for content search. Do not use `find`, `grep`, Glob, or Read.
```

### `claude/settings.json`

Claude Code [settings](https://docs.claude.com/en/docs/claude-code/settings): bypass-permissions default mode, disable 1M context, custom statusline.

```json
{
  "permissions": {
    "defaultMode": "bypassPermissions"
  },
  "skipDangerousModePermissionPrompt": true,
  "env": {
    "CLAUDE_CODE_DISABLE_1M_CONTEXT": "1"
  },
  "statusLine": {
    "type": "command",
    "command": "bash /home/dev/.claude/statusline-command.sh"
  }
}
```

### `claude/statusline-command.sh`

Custom [statusline](https://docs.claude.com/en/docs/claude-code/statusline): model, effort level, git branch, cwd, token usage. Reads guest-side `settings.json` so VM `effortLevel` can differ from the host.

```sh
#!/bin/sh
# Portable copy of the host statusline. Reads the guest's own
# ~/.claude/settings.json so VM-side effortLevel can differ from host.
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // ""')
dir=$(basename "$cwd")
effort_level=$(echo "$input" | jq -r '.effort.level // empty')

if [ -z "$effort_level" ]; then
  effort_level=$(jq -r '.effortLevel // "default"' "$HOME/.claude/settings.json" 2>/dev/null)
fi

case "$effort_level" in
  max)    effort="max" ;;
  xhigh)  effort="xhigh" ;;
  high)   effort="high" ;;
  medium) effort="med" ;;
  low)    effort="low" ;;
  *)      effort="$effort_level" ;;
esac

branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
fi

reset="\033[0m"
dim="\033[2m"
cyan="\033[36m"
blue="\033[34m"
yellow="\033[33m"

window=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
cu=$(echo "$input" | jq '.context_window.current_usage // empty')

used=""
used_pct=""
if [ "$cu" != "" ] && [ "$cu" != "null" ]; then
  cache_read=$(echo "$cu" | jq -r '.cache_read_input_tokens // 0')
  cache_create=$(echo "$cu" | jq -r '.cache_creation_input_tokens // 0')
  input_tok=$(echo "$cu" | jq -r '.input_tokens // 0')
  output_tok=$(echo "$cu" | jq -r '.output_tokens // 0')
  used=$(( cache_read + cache_create + input_tok + output_tok ))
  if [ -n "$window" ] && [ "$window" -gt 0 ] 2>/dev/null; then
    used_pct=$(awk "BEGIN{printf \"%.1f\", $used/$window*100}")
  fi
fi

fmt_tokens() {
  val=$1
  if [ "$val" -ge 1000 ] 2>/dev/null; then
    printf '%.1fk' "$(echo "$val" | awk '{printf "%.1f", $1/1000}')"
  else
    printf '%s' "$val"
  fi
}

fmt_window() {
  val=$1
  if [ "$val" -ge 1000 ] 2>/dev/null; then
    printf '%.0fk' "$(echo "$val" | awk '{printf "%.0f", $1/1000}')"
  else
    printf '%s' "$val"
  fi
}

left="${cyan}${model}${reset}"
left="${left}  ${dim}${effort}${reset}"
[ -n "$branch" ] && left="${left}  ${blue}${branch}${reset}"
left="${left}  ${yellow}${dir}${reset}"

right=""
if [ -n "$used" ] && [ -n "$window" ] && [ -n "$used_pct" ]; then
  used_fmt=$(fmt_tokens "$used")
  window_fmt=$(fmt_window "$window")
  right="${dim}${used_fmt} / ${window_fmt} ($(printf '%.0f' "$used_pct")%)${reset}"
fi

if [ -n "$right" ]; then
  printf "%b  %b" "$left" "$right"
else
  printf "%b" "$left"
fi
```

### `scripts/sync-claude-config.sh`

Pushes `claude/*` into the VM's `~/.claude/`. `settings.json` uses no-clobber semantics so VM-side tweaks (e.g. `/effort`) survive; pass `--force` to overwrite.

```bash
#!/bin/bash
# Push dev/lima/claude/* into the cc-dev VM's ~/.claude/.
# Use after editing files under ./claude/ to refresh the live VM without
# rebooting/reprovisioning. By default settings.json is copied with
# no-clobber semantics so VM-side changes (e.g. /effort) are not stomped.
# Pass --force to overwrite settings.json as well.
#
# Usage:  ./scripts/sync-claude-config.sh [--force] [HOST]
# Default HOST: lima-cc-dev

set -euo pipefail

FORCE=0
if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then
  FORCE=1
  shift
fi

HOST=${1:-lima-cc-dev}
SRC="$(cd "$(dirname "$0")/.." && pwd)/claude"

if [ ! -d "$SRC" ]; then
  echo "ERROR: source dir not found: $SRC" >&2
  exit 1
fi

ssh "$HOST" 'mkdir -p ~/.claude && chmod 700 ~/.claude'

# scripts: always overwrite (they are config-as-code)
for f in "$SRC"/*.sh; do
  [ -e "$f" ] || continue
  scp -q "$f" "$HOST:.claude/$(basename "$f")"
done
ssh "$HOST" 'chmod +x ~/.claude/*.sh 2>/dev/null || true'

# markdown files: always overwrite
for f in "$SRC"/*.md; do
  [ -e "$f" ] || continue
  scp -q "$f" "$HOST:.claude/$(basename "$f")"
done

# settings.json: seed only if missing on the guest, unless --force
if [ -f "$SRC/settings.json" ]; then
  if [ "$FORCE" = "1" ] || ! ssh "$HOST" 'test -f ~/.claude/settings.json'; then
    scp -q "$SRC/settings.json" "$HOST:.claude/settings.json"
    ssh "$HOST" 'chmod 600 ~/.claude/settings.json'
  else
    echo "skip ~/.claude/settings.json (already exists on $HOST; pass --force to overwrite)"
  fi
fi

echo "synced $SRC -> $HOST:.claude/"
```

## Usage

### Create / start the VM

```bash
limactl start --name=cc-dev cc-dev.yaml
```

### Stop / delete / recreate

```bash
limactl stop cc-dev
limactl delete cc-dev                 # destroys the disk
limactl start --name=cc-dev cc-dev.yaml   # recreate from scratch
```

Force-recreate in one shot:

```bash
limactl delete -f cc-dev && limactl start --name=cc-dev cc-dev.yaml
```

### Re-run provisioning without recreating

```bash
limactl factory-reset cc-dev   # wipes user data, keeps disk
limactl start cc-dev
```

### Connect

```bash
ssh lima-cc-dev          # uses Lima's generated ~/.lima/cc-dev/ssh.config + pinned port 2222
limactl shell cc-dev     # alternative
```

### Sync Claude config after edits

```bash
./scripts/sync-claude-config.sh           # no-clobber on settings.json
./scripts/sync-claude-config.sh --force   # overwrite settings.json too
```

### Tech-stack progress

```bash
ssh lima-cc-dev 'tail -f ~/.tech-stack.log'
ssh lima-cc-dev 'sudo journalctl -u lima-tech-stack -f'
ssh lima-cc-dev 'test -f ~/.tech-stack.done && echo done || echo running'
```
