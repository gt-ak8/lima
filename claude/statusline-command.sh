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
