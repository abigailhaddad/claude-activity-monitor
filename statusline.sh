#!/usr/bin/env bash
# Claude Code statusLine command. Prints a short one-liner showing the
# current break-monitor streak, with a tier hint once thresholds trip.
# Registered in ~/.claude/settings.json as `statusLine.command`.
# Reads state.json; silent/neutral if the monitor isn't running.

set -u

# stdin is Claude Code session info (JSON); we don't need it, but drain it
# so the writer doesn't block.
cat >/dev/null

ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE="$ROOT/data/state.json"
CONFIG="$ROOT/config.yaml"
NUDGE_FILE="$ROOT/stats/nudge.txt"
LAST_PROMPT_FILE="$ROOT/data/last_prompt.ts"

mtime() { stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null; }

# If a break was just registered (a nudged streak ended with a real
# idle gap), show a confirmation banner until the next UserPromptSubmit.
# This works even before the user has ever prompted — useful for
# freshly-unblocked sessions the user is returning to.
if [[ -f "$STATE" ]]; then
  last_release=$(jq -r '.last_release // 0' "$STATE" 2>/dev/null)
  if [[ -n "$last_release" && "$last_release" != "0" ]]; then
    last_prompt=0
    [[ -f "$LAST_PROMPT_FILE" ]] && last_prompt=$(mtime "$LAST_PROMPT_FILE")
    last_prompt=${last_prompt:-0}
    if (( last_release > last_prompt )); then
      printf 'break registered · Claude Code is unblocked'
      exit 0
    fi
  fi
fi

[[ -f "$STATE" && -f "$CONFIG" ]] || { printf 'break monitor: off'; exit 0; }

streak_start=$(jq -r '.streak_start // 0' "$STATE" 2>/dev/null)
[[ -z "$streak_start" || "$streak_start" == "0" ]] && { printf 'break: 0m'; exit 0; }

now=$(date +%s)
mins=$(( (now - streak_start) / 60 ))

yaml_int() { sed -nE "s/^$1:[[:space:]]*([0-9]+).*/\1/p" "$CONFIG"; }
gentle=$(yaml_int streak_limit_minutes)
firm=$(yaml_int firm_nudge_minutes)
hard=$(yaml_int hard_block_minutes)
idle=$(yaml_int idle_threshold_minutes)

# Source of truth for tier is nudge.txt (what hook.sh acts on). Fall
# back to streak math only if the nudge file is empty or stale — this
# prevents the statusline from claiming "FIRM NUDGE" while hook.sh is
# already blocking prompts based on a freshly-written hard_block.
tier=""
if [[ -s "$NUDGE_FILE" ]]; then
  nudge_age=$(( now - $(mtime "$NUDGE_FILE") ))
  if (( nudge_age < 180 )); then
    tier=$(head -n1 "$NUDGE_FILE" | sed -n 's/^TIER=//p')
  fi
fi

case "$tier" in
  hard_block)
    printf 'BLOCKED — %dm idle to release' "$idle" ;;
  firm)
    printf '%dm since break · FIRM NUDGE · blocked in %dm' "$mins" "$(( hard > mins ? hard - mins : 0 ))" ;;
  gentle)
    printf '%dm since break · NUDGING · blocked in %dm' "$mins" "$(( hard > mins ? hard - mins : 0 ))" ;;
  *)
    printf '%dm since break · nudge in %dm · blocked in %dm' "$mins" "$(( gentle > mins ? gentle - mins : 0 ))" "$(( hard > mins ? hard - mins : 0 ))" ;;
esac
