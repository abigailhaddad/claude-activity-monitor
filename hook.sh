#!/usr/bin/env bash
# Claude Code hook, registered for both UserPromptSubmit and Stop.
# Two jobs:
#   1. Touch data/last_prompt.ts — the monitor's canonical activity
#      signal. Fires on every prompt AND on every assistant-response
#      completion, so "user is engaged with Claude Code" is still
#      true during long tool runs and mid-response interjections
#      (UserPromptSubmit alone misses those).
#   2. On UserPromptSubmit only: read stats/active.txt and either
#      inject it as context (nudge tier) or refuse the prompt with
#      exit 2 (block tier). Also fires an OS banner so the nudge is
#      visible outside Claude's response body.
# Stop events deliberately skip the tier logic — exit 2 in a Stop
# hook blocks completion (would prevent Claude from ever finishing),
# and injecting a nudge at response-end is redundant with
# UserPromptSubmit's injection at the next prompt.
# Silent when no tier is active or when the monitor hasn't touched
# the file in STALE_SECONDS (treated as dead daemon).

ROOT="$(cd "$(dirname "$0")" && pwd)"
ACTIVE_FILE="$ROOT/stats/active.txt"
LAST_PROMPT_FILE="$ROOT/data/last_prompt.ts"
STALE_SECONDS=180

# Read the event payload off stdin (Claude Code pipes JSON). If jq is
# missing or stdin is empty (manual test invocation), default to
# UserPromptSubmit behavior — fail safe, since that path is the one
# that can actually nudge/refuse.
input=$(cat 2>/dev/null || true)
event=""
if [[ -n "$input" ]] && command -v jq >/dev/null 2>&1; then
  event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
fi

mkdir -p "$(dirname "$LAST_PROMPT_FILE")"
: > "$LAST_PROMPT_FILE"

# Stop hook: activity signal only. Must not exit 2 (that would block
# the response from ever completing) and must not inject text.
if [[ "$event" == "Stop" ]]; then
  exit 0
fi

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
