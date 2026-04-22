#!/usr/bin/env bash
# Continuously monitors Claude Code activity and nudges the user to take
# a break. The activity signal is data/last_prompt.ts — hook.sh touches
# it on every UserPromptSubmit, so only real user prompts count
# (mouse movement, typing outside Claude Code, background agents,
# autonomous loops, and Claude's own tool use do not).
#
#   private (gitignored)  -> data/state.json, data/monitor.log, data/last_prompt.ts
#   shareable (committed) -> stats/activity.log, stats/nudge.txt
#
# stats/nudge.txt is read by the Claude Code hook (hook.sh) on every
# user prompt; when non-empty, its contents get injected as context so
# Claude knows to tell the user to take a break. If the user manually
# deletes stats/nudge.txt the monitor interprets that as "I'm taking a
# break now, reset" and sets streak_start to now on the next poll.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$ROOT/data"
STATS_DIR="$ROOT/stats"
CONFIG="$ROOT/config.yaml"
mkdir -p "$DATA_DIR" "$STATS_DIR"

STATE_FILE="$DATA_DIR/state.json"
PRIVATE_LOG="$DATA_DIR/monitor.log"
PUBLIC_LOG="$STATS_DIR/activity.log"
NUDGE_FILE="$STATS_DIR/nudge.txt"
LAST_PROMPT_FILE="$DATA_DIR/last_prompt.ts"

# Minimal YAML reader. Supports three forms for a top-level key:
#   key: value                 — plain scalar
#   key: "quoted value"        — quotes stripped
#   key: |                     — literal block; following lines indented
#     line one                   by 2 spaces become the value (indent
#     line two                   stripped, newlines preserved)
# Trailing `# comment` on inline values is stripped.
yaml_get() {
  local key="$1" inline
  inline=$(sed -nE "s/^${key}:[[:space:]]*(.*)$/\1/p" "$CONFIG" | head -1)
  inline=$(printf '%s' "$inline" | sed -E 's/[[:space:]]*#.*$//; s/[[:space:]]+$//')
  if [[ "$inline" == "|" || "$inline" == "|-" || "$inline" == ">" ]]; then
    awk -v k="$key" '
      $0 ~ "^"k":[[:space:]]*[|>][-]?[[:space:]]*$" { in_block=1; next }
      in_block {
        if ($0 ~ /^  /)              { sub(/^  /, ""); print; next }
        if ($0 ~ /^[[:space:]]*$/)   { print ""; next }
        exit
      }
    ' "$CONFIG"
  else
    printf '%s' "$inline" | sed -E 's/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/'
  fi
}
yaml_int() { yaml_get "$1" | tr -d '[:space:]'; }

POLL_INTERVAL=$(yaml_int poll_interval_seconds)
IDLE_THRESHOLD=$(( $(yaml_int idle_threshold_minutes) * 60 ))
NUDGE_THRESHOLD=$(( $(yaml_int nudge_minutes) * 60 ))
BLOCK_THRESHOLD=$(( $(yaml_int block_minutes) * 60 ))
NOTIFY_COOLDOWN=$(( $(yaml_int notify_cooldown_minutes) * 60 ))

# Substitute {mins}, {idle_min}, {nudge_min} placeholders.
render_template() {
  local tpl="$1" mins="$2"
  local idle_min=$(( IDLE_THRESHOLD / 60 ))
  local nudge_min=$(( NUDGE_THRESHOLD / 60 ))
  tpl=${tpl//\{mins\}/$mins}
  tpl=${tpl//\{idle_min\}/$idle_min}
  tpl=${tpl//\{nudge_min\}/$nudge_min}
  printf '%s' "$tpl"
}

plog() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PRIVATE_LOG"; }
slog() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PUBLIC_LOG"; }

mtime() {
  # Portable file mtime in epoch seconds. BSD/macOS uses `stat -f %m`,
  # GNU/Linux uses `stat -c %Y`. Falls back silently on either.
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

latest_event_epoch() {
  # Activity = most recent UserPromptSubmit in any Claude Code session.
  # hook.sh touches $LAST_PROMPT_FILE on every prompt, so this mtime
  # is the canonical "user is engaged" signal. Mouse movement and
  # typing in other apps deliberately do NOT count — the tool is
  # scoped to coding with Claude.
  if [[ -f "$LAST_PROMPT_FILE" ]]; then
    mtime "$LAST_PROMPT_FILE"
  else
    echo 0
  fi
}

send_notification() {
  # Platform-agnostic banner notification. Preference order:
  #   1. osascript (macOS built-in) — routes through Script Editor;
  #      needs the user to grant Script Editor notification permission
  #      once, but otherwise just works.
  #   2. terminal-notifier (macOS, brew install terminal-notifier) —
  #      has its own app bundle. Fallback because its permission state
  #      can silently desync (exit 0 but no banner) on some setups.
  #   3. notify-send (Linux libnotify).
  # Pass urgency=urgent as the third arg to use a more jarring sound and
  # pierce Do Not Disturb (where the notifier supports it).
  local title="$1" body="$2" urgency="${3:-normal}"
  local sound="Glass"
  [[ "$urgency" == "urgent" ]] && sound="Basso"
  if command -v osascript >/dev/null 2>&1; then
    local t="${title//\\/\\\\}"; t="${t//\"/\\\"}"
    local b="${body//\\/\\\\}";  b="${b//\"/\\\"}"
    osascript -e "display notification \"${b}\" with title \"${t}\" sound name \"${sound}\"" >/dev/null 2>&1 || true
  elif command -v terminal-notifier >/dev/null 2>&1; then
    local flags=(-title "$title" -message "$body" -sound "$sound")
    [[ "$urgency" == "urgent" ]] && flags+=(-ignoreDnD)
    terminal-notifier "${flags[@]}" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    local urgency_flag=()
    [[ "$urgency" == "urgent" ]] && urgency_flag=(--urgency=critical)
    notify-send "${urgency_flag[@]}" "$title" "$body" >/dev/null 2>&1 || true
  fi
}

notify() {
  # All break-monitor notifications pass urgency=urgent so they pierce
  # Do Not Disturb / Focus modes. The whole point of this tool is to
  # tell the user things they would otherwise ignore.
  local mins="$1" tier="$2"
  local title body
  title=$(render_template "$(yaml_get "${tier}_notification_title")" "$mins")
  body=$(render_template  "$(yaml_get "${tier}_notification_body")"  "$mins")
  send_notification "$title" "$body" urgent
}

write_nudge() {
  local mins="$1" tier="$2" key body
  case "$tier" in
    nudge) key=nudge_instructions ;;
    block) key=block_message ;;
    *) return ;;
  esac
  body=$(render_template "$(yaml_get "$key")" "$mins")
  {
    printf 'TIER=%s\n' "$tier"
    printf '%s\n' "$body"
  } > "$NUDGE_FILE"
}

clear_nudge() { : > "$NUDGE_FILE"; }

read_state() {
  if [[ -f "$STATE_FILE" ]]; then cat "$STATE_FILE"
  else echo '{"last_event":0,"streak_start":0,"last_notified":0,"last_release":0,"last_tier":""}'
  fi
}

# last_tier is the most recent tier the monitor wrote to nudge.txt
# ("nudge"/"block", or "" if nudge was cleared). Lets the loop
# distinguish "monitor cleared nudge" (we set last_tier="") from
# "user manually deleted nudge to request a reset" (last_tier still
# non-empty but nudge.txt is gone).
write_state() {
  printf '{"last_event":%s,"streak_start":%s,"last_notified":%s,"last_release":%s,"last_tier":"%s"}\n' \
    "$1" "$2" "$3" "$4" "$5" > "$STATE_FILE"
}

plog "monitor started (pid=$$, nudge=${NUDGE_THRESHOLD}s, block=${BLOCK_THRESHOLD}s, idle=${IDLE_THRESHOLD}s, poll=${POLL_INTERVAL}s)"
[[ -f "$NUDGE_FILE" ]] || clear_nudge

while true; do
  now=$(date +%s)
  latest=$(latest_event_epoch); latest=${latest:-0}

  state=$(read_state)
  last_event=$(echo "$state" | jq -r '.last_event')
  streak_start=$(echo "$state" | jq -r '.streak_start')
  last_notified=$(echo "$state" | jq -r '.last_notified')
  last_release=$(echo "$state" | jq -r '.last_release // 0')
  last_tier=$(echo "$state" | jq -r '.last_tier // ""')

  # Manual reset: user deleted/emptied nudge.txt while the monitor
  # believed a nudge was in effect. Treat as "I'm taking a break now"
  # — clear the streak, fire a release notification if the prior
  # streak was significant, and skip the rest of this poll.
  nudge_empty=0
  [[ ! -s "$NUDGE_FILE" ]] && nudge_empty=1
  if [[ -n "$last_tier" ]] && (( nudge_empty == 1 )); then
    prior_streak=$(( last_event - streak_start ))
    (( prior_streak < 0 )) && prior_streak=0
    slog "manual_reset prior_streak_min=$(( prior_streak / 60 )) prior_tier=${last_tier}"
    if (( prior_streak >= NUDGE_THRESHOLD )); then
      last_release=$now
      send_notification "Claude Code: break registered" "Manual reset. You're unblocked." urgent
    fi
    streak_start=$now
    last_event=$now
    last_tier=""
    write_state "$last_event" "$streak_start" "$last_notified" "$last_release" "$last_tier"
    sleep "$POLL_INTERVAL"
    continue
  fi

  if (( latest > last_event )); then
    gap=$(( latest - last_event ))
    if (( last_event == 0 || gap > IDLE_THRESHOLD )); then
      if (( last_event > 0 )); then
        streak_len=$(( last_event - streak_start ))
        slog "break_end prior_streak_min=$(( streak_len / 60 )) gap_min=$(( gap / 60 ))"
        # If the prior streak had crossed at least the nudge threshold,
        # this break is a real "release" — log + notify so the user
        # knows they are unblocked.
        if (( streak_len >= NUDGE_THRESHOLD )); then
          last_release=$now
          slog "release prior_streak_min=$(( streak_len / 60 ))"
          send_notification "Claude Code: break registered" "You're unblocked. Welcome back." urgent
        fi
      fi
      streak_start=$latest
      clear_nudge
      last_tier=""
    fi
    last_event=$latest
  fi

  # Currently coding = last event is within idle threshold of now.
  if (( last_event > 0 )) && (( now - last_event < IDLE_THRESHOLD )); then
    active_streak=$(( now - streak_start ))
    tier=""
    if   (( active_streak >= BLOCK_THRESHOLD )); then tier=block
    elif (( active_streak >= NUDGE_THRESHOLD )); then tier=nudge
    fi
    if [[ -n "$tier" ]]; then
      mins=$(( active_streak / 60 ))
      write_nudge "$mins" "$tier"
      last_tier=$tier
      if (( now - last_notified >= NOTIFY_COOLDOWN )); then
        notify "$mins" "$tier"
        slog "nudged tier=${tier} streak_min=${mins}"
        last_notified=$now
      fi
    else
      clear_nudge
      last_tier=""
    fi
  else
    # On a break right now — no nudge needed.
    clear_nudge
    last_tier=""
  fi

  write_state "$last_event" "$streak_start" "$last_notified" "$last_release" "$last_tier"
  sleep "$POLL_INTERVAL"
done
