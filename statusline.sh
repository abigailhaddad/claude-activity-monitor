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
ACTIVE_FILE="$ROOT/stats/active.txt"
LAST_PROMPT_FILE="$ROOT/data/last_prompt.ts"

mtime() {
  # GNU/Linux (`stat -c %Y`) first, because BSD `stat -f` on Linux
  # silently prints filesystem info — success exit, junk output —
  # which poisons any arithmetic downstream.
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

# If a break was just registered, show a confirmation banner for a
# short window (or until the next prompt, whichever comes first).
# Time cap: without it, the SwiftBar menubar — which re-polls on a
# timer, not on prompts — would stay stuck on this banner forever
# after a manual_reset if the user doesn't prompt again soon, hiding
# the normal streak display.
RELEASE_BANNER_WINDOW=60
if [[ -f "$STATE" ]]; then
  last_release=$(jq -r '.last_release // 0' "$STATE" 2>/dev/null)
  if [[ -n "$last_release" && "$last_release" != "0" ]]; then
    last_prompt=0
    [[ -f "$LAST_PROMPT_FILE" ]] && last_prompt=$(mtime "$LAST_PROMPT_FILE")
    last_prompt=${last_prompt:-0}
    release_age=$(( $(date +%s) - last_release ))
    if (( last_release > last_prompt )) && (( release_age < RELEASE_BANNER_WINDOW )); then
      printf 'break registered · Claude Code is unblocked'
      exit 0
    fi
  fi
fi

[[ -f "$STATE" && -f "$CONFIG" ]] || { printf 'break monitor: off'; exit 0; }

# Monitor polls every 30s. If state.json is older than 2 minutes, the
# daemon is probably dead — render a stopped marker so the user isn't
# fooled by stale streak/idle numbers.
state_age=$(( $(date +%s) - $(mtime "$STATE") ))
if (( state_age > 120 )); then
  printf 'break monitor: stopped'
  exit 0
fi

streak_start=$(jq -r '.streak_start // 0' "$STATE" 2>/dev/null)
last_event=$(jq -r '.last_event // 0' "$STATE" 2>/dev/null)
block_start=$(jq -r '.block_start // 0' "$STATE" 2>/dev/null)
[[ "$block_start" =~ ^[0-9]+$ ]] || block_start=0
[[ -z "$streak_start" || "$streak_start" == "0" ]] && { printf 'break: 0m'; exit 0; }

now=$(date +%s)
mins=$(( (now - streak_start) / 60 ))

yaml_int() { sed -nE "s/^$1:[[:space:]]*([0-9]+).*/\1/p" "$CONFIG"; }
nudge_at=$(yaml_int nudge_minutes)
block_at=$(yaml_int block_minutes)
idle=$(yaml_int idle_threshold_minutes)

# Idle progress toward a break-end reset. last_event is updated by the
# monitor each poll (~30s cadence) to the time of the user's most
# recent Claude Code prompt submission. "now - last_event" climbs while
# they're idle and snaps back to ~0m the next poll after they prompt,
# which is the visible feedback the user wants.
idle_min=0
if [[ -n "$last_event" && "$last_event" != "0" ]]; then
  idle_sec=$(( now - last_event ))
  (( idle_sec < 0 )) && idle_sec=0
  idle_min=$(( idle_sec / 60 ))
  (( idle_min > idle )) && idle_min=$idle
fi

# Determine tier. Prefer active.txt (source of truth for what hook.sh
# will do on the next prompt), but fall back to streak math when
# active.txt is empty — it's empty while you're currently idle, but
# the streak hasn't reset yet, so we need to infer the tier ourselves
# to keep the statusline consistent with what the hook will actually do.
# Trust active.txt only while the daemon is alive (state.json freshness,
# checked above, is that liveness signal). Ageing out active.txt itself
# would be wrong: the monitor writes it once per tier transition, so its
# mtime is frozen and an hour-old block is still a live block.
tier=""
if [[ -s "$ACTIVE_FILE" ]]; then
  tier=$(head -n1 "$ACTIVE_FILE" | sed -n 's/^TIER=//p')
fi
if [[ -z "$tier" ]]; then
  if   (( mins >= block_at )); then tier=block
  elif (( mins >= nudge_at )); then tier=nudge
  fi
fi

# Two display modes, keyed off of whether the user is currently idle
# AND has a tier active (i.e. a streak worth breaking from):
#   - coding: "Nm since break · blocked in Xm" (or "BLOCKED · break: Xm left")
#   - break:  "break: Xm left" — only meaningful once a nudge / block
#             is in effect, since that's when the idle countdown actually
#             does something (clears the nudge or unblocks). Pre-nudge
#             pauses stay in coding mode so a freshly-reset streak
#             doesn't immediately flip into "break: 9m left".
blocked_in=$(( block_at > mins ? block_at - mins : 0 ))

# Minutes still to serve. A block is held for a full idle_threshold
# measured from block_start — the instant the block fired — not from the
# user's last prompt. The countdown has to be measured the same way the
# monitor releases, or the statusline promises a lift that won't come.
# block_start is 0 when the tier was inferred from streak math rather
# than read from a live block; fall back to idle progress there.
if [[ "$tier" == "block" && "$block_start" != "0" ]]; then
  served=$(( now - block_start ))
  (( served < 0 )) && served=0
  break_left=$(( (idle * 60 - served + 59) / 60 ))
  (( break_left < 0 )) && break_left=0
else
  break_left=$(( idle > idle_min ? idle - idle_min : 0 ))
fi

if [[ "$tier" == "block" ]]; then
  # The only state where prompts are actually refused. Say so plainly,
  # in both coding and idle mode — the countdown runs on block_start
  # either way, so there is nothing to distinguish.
  if (( break_left == 0 )); then
    printf 'BLOCKED · lifting now'
  else
    printf 'BLOCKED · %dm left' "$break_left"
  fi
elif (( idle_min > 0 )) && [[ -n "$tier" ]]; then
  # Nudge tier, idling. NOTHING is enforced here — prompts go through
  # untouched. This countdown only says when the streak resets itself,
  # so it must not borrow the block's vocabulary: "break: 9m left" read
  # as "you are on a mandated break" when it meant "9 more idle minutes
  # and your streak zeroes out".
  if (( break_left == 0 )); then
    printf '%dm coding · streak resetting' "$mins"
  else
    printf '%dm coding · resets in %dm idle' "$mins" "$break_left"
  fi
else
  printf '%dm since break · blocked in %dm' "$mins" "$blocked_in"
fi
