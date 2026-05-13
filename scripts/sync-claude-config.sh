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
