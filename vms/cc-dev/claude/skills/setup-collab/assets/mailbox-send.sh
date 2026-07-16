#!/usr/bin/env bash
# Append a message to the shared mailbox.
# Usage: mailbox-send.sh <from> <text> [mentions-csv]
#   mentions-csv: optional comma-separated ids whose reply/action is expected, e.g. "dev,reviewer"
set -euo pipefail
FROM="${1:?usage: mailbox-send.sh <from> <text> [mentions-csv]}"
TEXT="${2:?usage: mailbox-send.sh <from> <text> [mentions-csv]}"
MENTIONS_CSV="${3:-}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAILBOX="$DIR/mailbox.jsonl"
jq -nc --arg from "$FROM" --arg text "$TEXT" --arg mentions "$MENTIONS_CSV" \
  '{from:$from, text:$text,
    mentions: ($mentions | if . == "" then [] else (split(",") | map(gsub("^\\s+|\\s+$";""))) end)}' \
  >> "$MAILBOX"
echo "sent: $FROM${MENTIONS_CSV:+ (@$MENTIONS_CSV)}: $TEXT"
