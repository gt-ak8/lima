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
        [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)= ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${!key:-}"
        [ -n "$val" ] || { echo "ERROR: $key not set in $DIR/.env"; exit 1; }
        set_args+=(--set ".param.$key = \"$val\"")
      done < "$DIR/.env.example"

      # Render vm.yaml -> $DIR/.lima.yaml with @@BASE@@ replaced by an absolute
      # file:// URL. Must live inside $DIR so Lima resolves provision script
      # paths (`./scripts/setup.sh`) against the VM's own directory.
      # Lima rejects `../` in relative base locators, and `--set .base` runs
      # after base merging, so neither shortcut works.
      BASE_URL="file://$(cd base && pwd)/base.yaml"
      RENDERED="$DIR/.lima.yaml"
      sed "s|@@BASE@@|$BASE_URL|g" "$DIR/vm.yaml" > "$RENDERED"
      limactl start --name="$VM" "$RENDERED" "${set_args[@]}"
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
