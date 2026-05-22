# lima — multi-VM Claude / agent setup

## Overview

Lima-based fleet of Debian 12 VMs for Claude Code and scoped agent sandboxes.
A shared base template provides the common CLI toolkit; each VM extends it with
its own tools, mounts, and credentials.

Refs: [Lima](https://lima-vm.io/) · [Lima provisioning](https://lima-vm.io/docs/config/provision/) · [Claude Code](https://docs.claude.com/en/docs/claude-code/overview).

## Layout

```
.
├── base/
│   ├── base.yaml             # shared Lima template (inherits _images/debian-12)
│   ├── provision.sh          # system: apt CLI toolkit, gh, fd, zsh, swap, starship
│   └── user-provision.sh     # user: known_hosts, git identity, base rc wiring
├── vms/
│   └── cc-dev/               # one folder per VM, folder name = VM name
│       ├── vm.yaml           # `base: [../../base/base.yaml]` + VM-specific overrides
│       ├── scripts/          # VM-specific provisioning
│       ├── claude/           # optional: synced into guest ~/.claude/ on start
│       ├── .env.example      # declares required PARAM_* keys
│       └── .env              # gitignored, user-supplied values
└── justfile                  # generic recipes take the VM name as arg
```

Lima merges `provision:` lists by **prepending** base entries, so the run
order is: `base/provision.sh` → `vms/<vm>/scripts/*-deps.sh` (system) →
`base/user-provision.sh` → `vms/<vm>/scripts/*-setup.sh` (user).

## Prerequisites

- [`lima`](https://lima-vm.io/docs/installation/)
- [`just`](https://github.com/casey/just#installation)

## Usage

```bash
just                       # list recipes
just list                  # list defined VMs
just start cc-dev          # create or start a VM
just stop cc-dev
just shell cc-dev
just delete cc-dev
just recreate cc-dev       # force-delete + start fresh
just factory-reset cc-dev  # wipe user data, keep disk
```

cc-dev-specific helpers:

```bash
just sync-claude           # push cc-dev/claude/* to lima-cc-dev:~/.claude/ (auto-runs on start)
just sync-claude --force   # also overwrite settings.json
just tech-stack-log        # tail async installer log
just tech-stack-status     # done | running
```

## First-time setup of cc-dev

```bash
cp vms/cc-dev/.env.example vms/cc-dev/.env
# edit vms/cc-dev/.env: HOST_PATH, GIT_NAME, GIT_EMAIL, GIT_SIGNING_KEY
just start cc-dev
```

Inside the VM (`just shell cc-dev`):

```bash
test -f ~/.tech-stack.done && echo done || echo running   # wait for async installer
gh auth login                                              # web flow
claude                                                     # auth flow
wt --version                                               # worktrunk on PATH
```

SSH commit signing already works via the forwarded host agent (`forwardAgent: true`).

## Adding a new VM

1. `mkdir -p vms/<name>/scripts`
2. `vms/<name>/vm.yaml`:

   ```yaml
   base:
     - ../../base/base.yaml

   memory: "2GiB"

   param:
     SOME_TOKEN: ""   # extra creds beyond the base GIT_* keys

   provision:
     - mode: user
       file: ./scripts/setup.sh
   ```

3. `vms/<name>/scripts/setup.sh` - install the tools this VM needs, idempotent.
4. `vms/<name>/.env.example` - document every key the VM reads.
5. `cp .env.example .env`, fill in.
6. `just start <name>`.

The justfile reads `vms/<name>/.env.example` to determine required keys and
forwards each one to Lima as `--set ".param.<key>=..."`. Inside provision
scripts they are visible as `PARAM_<key>`.

## Key design points

- 8 GiB RAM + 4 GiB swap on cc-dev (Claude native installer ~3.5 GiB RSS).
- Debian base (no snapd, no unattended-upgrades, leaner cloud-init).
- Boot-time service disables (apt-daily, man-db, motd-news, fwupd, networkd-wait-online).
- virtiofs mounts (when declared).
- cc-dev pins SSH port `2222` so `ssh lima-cc-dev` stays stable across restarts.
- cc-dev's tech-stack install runs as a transient systemd unit (`lima-tech-stack`)
  to outlive cloud-init's ~10 min boot-script timeout.
- All provision scripts are idempotent: they re-run on every `limactl start`.
