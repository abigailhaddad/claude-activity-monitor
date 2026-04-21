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
if (( mins >= hard )); then
  printf 'BLOCKED — %dm idle to release' "$idle"
elif (( mins >= firm )); then
  printf '%dm since break · FIRM NUDGE · blocked in %dm' "$mins" "$(( hard - mins ))"
elif (( mins >= gentle )); then
  printf '%dm since break · NUDGING · blocked in %dm' "$mins" "$(( hard - mins ))"
else
  printf '%dm since break · nudge in %dm · blocked in %dm' "$mins" "$(( gentle - mins ))" "$(( hard - mins ))"
fi
