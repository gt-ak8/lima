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
- A host directory to mount into the VM. Edit both `mounts[0].location` and `mounts[0].mountPoint` in [`cc-dev.yaml`](./cc-dev.yaml) to your host path (kept identical so the guest sees the same absolute path).

## Directory layout

| File | Purpose |
|------|---------|
| [`cc-dev.yaml`](./cc-dev.yaml) | Lima VM spec: base image, memory, user, SSH, mount, provision hooks. Update `mounts[0]` before first start. |
| [`scripts/system-deps.sh`](./scripts/system-deps.sh) | Root provisioning: apt deps + gh CLI in a single update pass, `fdfind`→`fd` symlink, zsh as dev's default, boot-time service disables, 4 GiB swap, starship. |
| [`scripts/user-setup.sh`](./scripts/user-setup.sh) | User provisioning: known_hosts seed, git identity + SSH commit signing, Claude Code install, zsh/bash rc wiring, then stages the async tech-stack installer as a transient systemd unit. Watch with `tail -f ~/.tech-stack.log`; done marker is `~/.tech-stack.done`. |
| [`scripts/sync-claude-config.sh`](./scripts/sync-claude-config.sh) | Pushes `claude/*` into the VM's `~/.claude/`. `settings.json` uses no-clobber semantics so VM-side tweaks (e.g. `/effort`) survive; pass `--force` to overwrite. |
| [`claude/CLAUDE.md`](./claude/CLAUDE.md) | Global Claude Code instructions inside the VM. |
| [`claude/settings.json`](./claude/settings.json) | Claude Code [settings](https://docs.claude.com/en/docs/claude-code/settings): bypass-permissions default mode, disable 1M context, custom statusline. |
| [`claude/statusline-command.sh`](./claude/statusline-command.sh) | Custom [statusline](https://docs.claude.com/en/docs/claude-code/statusline): model, effort level, git branch, cwd, token usage. Reads guest-side `settings.json` so VM `effortLevel` can differ from the host. |

## Usage

### Create / start the VM

```bash
limactl start --name=cc-dev cc-dev.yaml
```

### Stop / delete / recreate

```bash
limactl stop cc-dev
limactl delete cc-dev                       # destroys the disk
limactl start --name=cc-dev cc-dev.yaml     # recreate from scratch
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
