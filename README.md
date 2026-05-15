# cc-dev — Lima VM for Claude Code

## Overview

Debian 12 Lima VM preconfigured for [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) with an async tech-stack installer (bun, node/nvm, java/gradle/maven via sdkman, rust + just) and a synced `~/.claude/` config.

Key design points:
- 8 GiB RAM + 4 GiB swap (Claude native installer allocates ~3.5 GiB RSS; 4 GiB OOM-killed it).
- Debian base (no snapd, no unattended-upgrades, leaner cloud-init than Ubuntu LTS).
- Boot-time service disables (apt-daily, man-db, motd-news, fwupd, networkd-wait-online, etc.) to shave seconds off every restart.
- virtiofs mount of a host project dir at the same absolute path inside the guest (so paths resolve identically on both sides).
- SSH host port pinned to `2222` so `ssh lima-cc-dev` stays stable across restarts.
- Tech-stack install staged as a transient systemd unit (`lima-tech-stack`) to outlive cloud-init's ~10 min boot-script timeout.

Refs: [Lima](https://lima-vm.io/) · [Lima provisioning](https://lima-vm.io/docs/config/provision/) · [Claude Code settings](https://docs.claude.com/en/docs/claude-code/settings).

## Prerequisites

- `lima` installed: [install guide](https://lima-vm.io/docs/installation/).
- `just` installed: [install guide](https://github.com/casey/just#installation).
- A host directory to mount into the VM (set via `HOST_PATH` in `.env`; mirrored to the same absolute path inside the guest).

## Setup

```bash
cp .env.example .env
# edit .env: HOST_PATH, GIT_NAME, GIT_EMAIL, GIT_SIGNING_KEY
just start
```

`just` loads `.env` and forwards values to Lima as `param:` entries (see [`cc-dev.yaml`](./cc-dev.yaml)), which are exposed to provision scripts as `PARAM_<key>` env vars and substituted into the yaml via `{{ .Param.<key> }}`. `.env` is gitignored so the repo stays publishable.

## Directory layout

| File | Purpose |
|------|---------|
| [`justfile`](./justfile) | Entry point: `just start / stop / delete / recreate / shell / sync-claude / tech-stack-log / tech-stack-status`. Loads `.env` via `set dotenv-load`. |
| [`.env.example`](./.env.example) | Template for `.env` (gitignored): host mount path + git identity + SSH signing pubkey. |
| [`cc-dev.yaml`](./cc-dev.yaml) | Lima VM spec: base image, memory, user, SSH, mount, provision hooks, `param:` block. |
| [`scripts/system-deps.sh`](./scripts/system-deps.sh) | Root provisioning: apt deps + gh CLI in a single update pass, `fdfind`->`fd` symlink, zsh as dev's default, boot-time service disables, 4 GiB swap, starship. |
| [`scripts/user-setup.sh`](./scripts/user-setup.sh) | User provisioning: known_hosts seed, git identity + SSH commit signing (from `PARAM_*`), Claude Code install, zsh/bash rc wiring, then stages the async tech-stack installer as a transient systemd unit. Watch with `tail -f ~/.tech-stack.log`; done marker is `~/.tech-stack.done`. |
| [`scripts/sync-claude-config.sh`](./scripts/sync-claude-config.sh) | Pushes `claude/*` into the VM's `~/.claude/`. `settings.json` uses no-clobber semantics so VM-side tweaks (e.g. `/effort`) survive; pass `--force` to overwrite. |
| [`claude/CLAUDE.md`](./claude/CLAUDE.md) | Global Claude Code instructions inside the VM. |
| [`claude/settings.json`](./claude/settings.json) | Claude Code [settings](https://docs.claude.com/en/docs/claude-code/settings): bypass-permissions default mode, disable 1M context, custom statusline. |
| [`claude/statusline-command.sh`](./claude/statusline-command.sh) | Custom [statusline](https://docs.claude.com/en/docs/claude-code/statusline): model, effort level, git branch, cwd, token usage. Reads guest-side `settings.json` so VM `effortLevel` can differ from the host. |

## Usage

```bash
just                       # list recipes
just start                 # create or start the VM
just stop
just delete                # destroys the disk
just recreate              # force-delete + start from scratch
just factory-reset         # wipe user data, keep disk (re-runs provisioning on next start)
just shell                 # ssh lima-cc-dev (pinned port 2222)
just sync-claude           # push claude/* into VM ~/.claude/ (no-clobber settings.json)
just sync-claude --force   # also overwrite settings.json
just tech-stack-log        # tail async installer log inside VM
just tech-stack-status     # 'done' or 'running'
```

## First-time setup inside the VM

Provisioning installs the tools but cannot log you in to interactive services. After the first `just start`, run these inside the VM (`just shell`):

```bash
# Wait for the async tech-stack installer to finish (bun, node, java, rust, just, worktrunk, ...).
test -f ~/.tech-stack.done && echo done || echo running

# GitHub CLI: opens a browser-based device flow.
gh auth login            # pick: GitHub.com, SSH, use existing key, login with web browser

# Claude Code: launches the auth flow on first run.
claude                   # follow the prompt to sign in

# Verify Worktrunk is on PATH (cargo install puts it under ~/.cargo/bin via the rc lines).
wt --version
```

SSH commit signing already works via the forwarded host agent (`forwardAgent: true` in `cc-dev.yaml`); no key setup needed inside the VM.
