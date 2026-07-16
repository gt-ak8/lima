#!/usr/bin/env bash
# Stream messages from the OTHER agents. Usage: mailbox-watch.sh <me>
# Emits one line per new message NOT sent by <me>, annotated with mentions:
#   "<from>: <text>"                                    (no mentions)
#   "<from> [mentions: a, b]: <text>"                   (mentions others)
#   "<from> [mentions: a, you]: <text>"                 (you are mentioned -> reply expected)
set -euo pipefail
ME="${1:?usage: mailbox-watch.sh <me>}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAILBOX="$DIR/mailbox.jsonl"
touch "$MAILBOX"
# -n0: only lines appended after the monitor starts. -F: survive truncation.
tail -n0 -F "$MAILBOX" \
  | jq --unbuffered -rc --arg me "$ME" '
      select(.from != $me)
      | (.mentions // []) as $ms
      | ($ms | map(if . == $me then "you" else . end)) as $shown
      | (if ($ms | length) > 0 then " [mentions: " + ($shown | join(", ")) + "]" else "" end) as $tag
      | "\(.from)\($tag): \(.text)"'
