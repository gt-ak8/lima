set dotenv-load := true

# List available recipes.
default:
    @just --list

# Create or start the cc-dev VM (sources .env, forwards values to Lima).
start:
    @if [ -n "$(limactl list -q cc-dev 2>/dev/null)" ]; then \
      limactl start cc-dev; \
    else \
      [ -n "${HOST_PATH:-}" ]        || { echo "ERROR: HOST_PATH not set (copy .env.example to .env)"; exit 1; }; \
      [ -n "${GIT_NAME:-}" ]         || { echo "ERROR: GIT_NAME not set"; exit 1; }; \
      [ -n "${GIT_EMAIL:-}" ]        || { echo "ERROR: GIT_EMAIL not set"; exit 1; }; \
      [ -n "${GIT_SIGNING_KEY:-}" ]  || { echo "ERROR: GIT_SIGNING_KEY not set"; exit 1; }; \
      limactl start --name=cc-dev cc-dev.yaml \
        --set ".param.HOST_PATH = \"$HOST_PATH\"" \
        --set ".param.GIT_NAME = \"$GIT_NAME\"" \
        --set ".param.GIT_EMAIL = \"$GIT_EMAIL\"" \
        --set ".param.GIT_SIGNING_KEY = \"$GIT_SIGNING_KEY\""; \
    fi
    just sync-claude

# Stop the VM.
stop:
    limactl stop cc-dev

# Delete the VM (destroys the disk).
delete:
    limactl delete cc-dev

# Force-delete and recreate from scratch.
recreate:
    limactl delete -f cc-dev
    just start

# Wipe user data but keep the disk; re-runs provisioning on next start.
factory-reset:
    limactl factory-reset cc-dev

# SSH into the VM.
shell:
    ssh lima-cc-dev

# Sync host claude/* into the VM's ~/.claude/. Pass --force to overwrite settings.json.
sync-claude *args:
    ./scripts/sync-claude-config.sh {{ args }}

# Tail the async tech-stack installer log inside the VM.
tech-stack-log:
    ssh lima-cc-dev 'tail -f ~/.tech-stack.log'

# Print 'done' or 'running' for the async tech-stack installer.
tech-stack-status:
    ssh lima-cc-dev 'test -f ~/.tech-stack.done && echo done || echo running'
