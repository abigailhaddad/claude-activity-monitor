#!/usr/bin/env bash
# Claude Code UserPromptSubmit hook. Reads stats/nudge.txt and either
# injects it as context (gentle/firm tiers) or blocks the prompt with
# exit 2 (hard_block). Silent when no nudge is active or when the
# monitor hasn't touched the file in STALE_SECONDS (treated as dead).
#
# The break monitor's activity signal is system-wide input idle time
# (ioreg HIDIdleTime), read directly by monitor.sh — this hook does
# not need to record anything.

ROOT="$(cd "$(dirname "$0")" && pwd)"
NUDGE_FILE="$ROOT/stats/nudge.txt"
STALE_SECONDS=180

[[ -s "$NUDGE_FILE" ]] || exit 0

now=$(date +%s)
mtime=$(stat -f %m "$NUDGE_FILE" 2>/dev/null || stat -c %Y "$NUDGE_FILE" 2>/dev/null || echo 0)
(( now - mtime > STALE_SECONDS )) && exit 0

tier=$(head -n1 "$NUDGE_FILE" | sed -n 's/^TIER=//p')
body=$(tail -n +2 "$NUDGE_FILE")

if [[ "$tier" == "hard_block" ]]; then
  printf '%s\n' "$body" >&2
  exit 2
fi

printf '%s\n' "$body"
exit 0
