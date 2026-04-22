#!/usr/bin/env bash
# Claude Code hook, registered for both UserPromptSubmit and Stop.
# Scope (Claude-Code-side only): activity signal, one-shot nudge
# injection, and hard-block enforcement. All OS-side nagware — banners,
# audio — lives in monitor.sh, outside Claude Code.
#
# Three jobs:
#   1. Touch data/last_prompt.ts — the monitor's canonical activity
#      signal. Fires on every prompt AND on every assistant-response
#      completion (Stop), so "user is engaged with Claude Code" stays
#      true during long tool runs.
#   2. On UserPromptSubmit while in nudge tier: inject the nudge
#      instruction ONCE per tier-epoch, globally across every open
#      Claude Code session. Gate: active.txt mtime > INJECTED_FILE
#      mtime. First prompt anywhere during this nudge epoch wins; all
#      subsequent prompts (same chat or other chats) stay silent until
#      the monitor flips tier again (which touches active.txt and
#      re-opens the gate).
#   3. On UserPromptSubmit while in block tier: refuse the prompt
#      (exit 2) and print the block message to stderr every time.
#      No "once per epoch" gating here — the whole point is to refuse
#      every attempt until the user actually idles long enough.
# Stop events never exit 2 (would block response completion) and
# never inject or refuse — only the next prompt does.

ROOT="$(cd "$(dirname "$0")" && pwd)"
ACTIVE_FILE="$ROOT/stats/active.txt"
LAST_PROMPT_FILE="$ROOT/data/last_prompt.ts"
# Marker: "the nudge poem has been injected for the current tier-epoch."
# monitor.sh only rewrites active.txt on tier transitions, so comparing
# its mtime against this marker lets us inject exactly once per epoch
# across every open Claude Code session.
INJECTED_FILE="$ROOT/data/last_injected.ts"
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

# Stop hook: exit 0 silently. We deliberately do NOT touch
# last_prompt.ts here. Response-end is not engagement — the user
# may have walked away while Claude was streaming. Only actual
# UserPromptSubmit events count as activity, so an idle user is
# genuinely idle even if Claude is still producing a response or
# an autonomous /loop is running behind them.
if [[ "$event" == "Stop" ]]; then
  exit 0
fi

now=$(date +%s)
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# Block tier is checked BEFORE touching last_prompt.ts. If we touched
# it on every rejected attempt, the user could never unblock: each
# blocked prompt would reset the monitor's idle countdown and extend
# the break indefinitely. A refused prompt is not engagement; the
# user's break clock must keep running.
if [[ -s "$ACTIVE_FILE" ]]; then
  active_mtime=$(mtime_of "$ACTIVE_FILE")
  if (( now - active_mtime <= STALE_SECONDS )); then
    tier=$(head -n1 "$ACTIVE_FILE" | sed -n 's/^TIER=//p')
    if [[ "$tier" == "block" ]]; then
      body=$(tail -n +2 "$ACTIVE_FILE")
      printf '%s\n' "$body" >&2
      exit 2
    fi
  fi
fi

# Not blocked — real engagement. Update activity signal.
: > "$LAST_PROMPT_FILE"

[[ -s "$ACTIVE_FILE" ]] || exit 0
active_mtime=$(mtime_of "$ACTIVE_FILE")
(( now - active_mtime > STALE_SECONDS )) && exit 0
tier=$(head -n1 "$ACTIVE_FILE" | sed -n 's/^TIER=//p')
body=$(tail -n +2 "$ACTIVE_FILE")

if [[ "$tier" == "nudge" ]]; then
  injected_mtime=0
  [[ -f "$INJECTED_FILE" ]] && injected_mtime=$(mtime_of "$INJECTED_FILE")
  # Only inject if the tier-epoch (active.txt mtime) is newer than the
  # last injection. Races between concurrent sessions are benign —
  # worst case the poem gets injected in two chats nearly simultaneously
  # once per epoch, which is still orders of magnitude better than
  # every-prompt-everywhere.
  if (( active_mtime > injected_mtime )); then
    touch "$INJECTED_FILE"
    printf '%s\n' "$body"
  fi
  exit 0
fi

exit 0
