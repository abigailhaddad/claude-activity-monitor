#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook. Two jobs:
#   1. Touch data/last_prompt.ts — the monitor's canonical activity
#      signal. Every UserPromptSubmit extends the streak; anything
#      else (mouse, typing outside Claude, background agents) does not.
#   2. Read stats/active.txt and either inject it as context
#      (nudge tier) or refuse the prompt with exit 2 (block tier).
#      Also fires an OS banner so the nudge is visible, not just
#      present in Claude's response body.
# Silent when no tier is active or when the monitor hasn't touched
# the file in STALE_SECONDS (treated as dead daemon).

ROOT="$(cd "$(dirname "$0")" && pwd)"
ACTIVE_FILE="$ROOT/stats/active.txt"
LAST_PROMPT_FILE="$ROOT/data/last_prompt.ts"
STALE_SECONDS=180

mkdir -p "$(dirname "$LAST_PROMPT_FILE")"
: > "$LAST_PROMPT_FILE"

banner() {
  # Fire a small OS banner for the nudge. osascript first (reliable on
  # macOS), terminal-notifier fallback, notify-send on Linux. Failures
  # are swallowed — the banner is bonus, the poem / refusal is the
  # real nudge.
  local title="$1" body="$2" sound="${3:-Glass}"
  if command -v osascript >/dev/null 2>&1; then
    local t="${title//\\/\\\\}"; t="${t//\"/\\\"}"
    local b="${body//\\/\\\\}";  b="${b//\"/\\\"}"
    osascript -e "display notification \"${b}\" with title \"${t}\" sound name \"${sound}\"" >/dev/null 2>&1 &
  elif command -v terminal-notifier >/dev/null 2>&1; then
    terminal-notifier -title "$title" -message "$body" -sound "$sound" >/dev/null 2>&1 &
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" >/dev/null 2>&1 &
  fi
}

[[ -s "$ACTIVE_FILE" ]] || exit 0

now=$(date +%s)
mtime=$(stat -c %Y "$ACTIVE_FILE" 2>/dev/null || stat -f %m "$ACTIVE_FILE" 2>/dev/null || echo 0)
(( now - mtime > STALE_SECONDS )) && exit 0

tier=$(head -n1 "$ACTIVE_FILE" | sed -n 's/^TIER=//p')
body=$(tail -n +2 "$ACTIVE_FILE")

case "$tier" in
  nudge) banner "Break nudge" "Stand up, stretch, look away." Glass ;;
  block) banner "Claude Code paused" "Break required before you can prompt again." Basso ;;
esac

if [[ "$tier" == "block" ]]; then
  printf '%s\n' "$body" >&2
  exit 2
fi

printf '%s\n' "$body"
exit 0
