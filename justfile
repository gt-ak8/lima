# Per-VM justfile. All generic recipes take the VM name as their first arg.
# Per-VM config lives under vms/<name>/ (vm.yaml + .env + scripts + extras).
# Per-VM .env loaded inside `start` only.

set dotenv-load := false

# List available recipes.
default:
    @just --list

# List the VMs defined in this repo.
list:
    @ls vms/ 2>/dev/null

# Create or start a VM (sources vms/<vm>/.env, syncs claude/ if present).
start vm:
    #!/usr/bin/env bash
    set -euo pipefail
    VM='{{vm}}'
    DIR="vms/$VM"
    [ -d "$DIR" ]              || { echo "ERROR: $DIR not found"; exit 1; }
    [ -f "$DIR/vm.yaml" ]      || { echo "ERROR: $DIR/vm.yaml missing"; exit 1; }
    [ -f "$DIR/.env" ]         || { echo "ERROR: $DIR/.env missing (copy .env.example)"; exit 1; }
    [ -f "$DIR/.env.example" ] || { echo "ERROR: $DIR/.env.example missing"; exit 1; }

    set -a; . "$DIR/.env"; set +a

    if [ -n "$(limactl list -q "$VM" 2>/dev/null)" ]; then
      limactl start "$VM"
    else
      # Required keys: anything assigned at top-level in .env.example.
      # `${!key}` is bash indirect expansion; missing values fail loud.
      set_args=()
      while IFS= read -r line; do
        key=$(printf '%s\n' "$line" | grep -oE '^[A-Z_][A-Z0-9_]*=' | tr -d '=')
        [ -n "$key" ] || continue
        val="${!key:-}"
        [ -n "$val" ] || { echo "ERROR: $key not set in $DIR/.env"; exit 1; }
        set_args+=(--set ".param.$key = \"$val\"")
      done < "$DIR/.env.example"
      limactl start --name="$VM" "$DIR/vm.yaml" "${set_args[@]}"
    fi

    if [ -d "$DIR/claude" ] && [ -x "$DIR/scripts/sync-claude-config.sh" ]; then
      "$DIR/scripts/sync-claude-config.sh" "lima-$VM"
    fi

# Stop a VM.
stop vm:
    limactl stop {{vm}}

# Delete a VM (destroys the disk).
delete vm:
    limactl delete {{vm}}

# Force-delete and recreate from scratch.
recreate vm:
    limactl delete -f {{vm}}
    just start {{vm}}

# Wipe user data but keep the disk; re-runs provisioning on next start.
factory-reset vm:
    limactl factory-reset {{vm}}

# SSH into a VM.
shell vm:
    ssh lima-{{vm}}

# Sync cc-dev's claude/* into the guest's ~/.claude/. Pass --force to overwrite settings.json.
sync-claude *args:
    ./vms/cc-dev/scripts/sync-claude-config.sh {{ args }}

# Tail the cc-dev async tech-stack installer log.
tech-stack-log:
    ssh lima-cc-dev 'tail -f ~/.tech-stack.log'

# Print 'done' or 'running' for the cc-dev async tech-stack installer.
tech-stack-status:
    ssh lima-cc-dev 'test -f ~/.tech-stack.done && echo done || echo running'
