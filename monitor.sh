#!/usr/bin/env bash
# Continuously monitors Claude Code activity and nudges the user to take a
# break. The activity signal is data/user_activity.ts — hook.sh touches it
# on every UserPromptSubmit, so only real user prompts count (background
# agents, autonomous loops, and Claude's own tool use do not).
#
#   private (gitignored)  -> data/state.json, data/monitor.log, data/user_activity.ts
#   shareable (committed) -> stats/activity.log, stats/nudge.txt
#
# stats/nudge.txt is read by the Claude Code hook (hook.sh) on every user
# prompt; when non-empty, its contents get injected as context so Claude
# knows to tell the user to take a break.

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
ACTIVITY_FILE="$DATA_DIR/user_activity.ts"

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
STREAK_LIMIT=$(( $(yaml_int streak_limit_minutes) * 60 ))
FIRM_THRESHOLD=$(( $(yaml_int firm_nudge_minutes) * 60 ))
HARD_BLOCK_THRESHOLD=$(( $(yaml_int hard_block_minutes) * 60 ))
NOTIFY_COOLDOWN=$(( $(yaml_int notify_cooldown_minutes) * 60 ))
CODING_APPS=$(yaml_get coding_apps)

# Substitute {mins}, {idle_min}, {streak_limit_min} placeholders.
render_template() {
  local tpl="$1" mins="$2"
  local idle_min=$(( IDLE_THRESHOLD / 60 ))
  local streak_limit_min=$(( STREAK_LIMIT / 60 ))
  tpl=${tpl//\{mins\}/$mins}
  tpl=${tpl//\{idle_min\}/$idle_min}
  tpl=${tpl//\{streak_limit_min\}/$streak_limit_min}
  printf '%s' "$tpl"
}

plog() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PRIVATE_LOG"; }
slog() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PUBLIC_LOG"; }

mtime() {
  # Portable file mtime in epoch seconds. BSD/macOS uses `stat -f %m`,
  # GNU/Linux uses `stat -c %Y`. Falls back silently on either.
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

user_idle_seconds() {
  # Seconds since the user's last mouse/keyboard input (system-wide).
  # macOS: IOKit HIDIdleTime. Linux X11: xprintidle. Prints 0 if neither.
  if command -v ioreg >/dev/null 2>&1; then
    ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'
  elif command -v xprintidle >/dev/null 2>&1; then
    echo $(( $(xprintidle 2>/dev/null || echo 0) / 1000 ))
  else
    echo 0
  fi
}

frontmost_app() {
  # macOS: frontmost application name via AppleScript. Linux: best-effort
  # via xdotool. Empty string if unavailable.
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null
  elif command -v xdotool >/dev/null 2>&1; then
    xdotool getactivewindow getwindowname 2>/dev/null
  fi
}

in_coding_app() {
  # Returns 0 if the frontmost app matches any CODING_APPS entry
  # (case-insensitive substring). Empty list or detection failure
  # means "always count" so the filter never locks the user out.
  [[ -z "$CODING_APPS" ]] && return 0
  local app app_lc
  app=$(frontmost_app)
  [[ -z "$app" ]] && return 0
  app_lc=$(printf '%s' "$app" | tr '[:upper:]' '[:lower:]')
  local IFS=','
  for entry in $CODING_APPS; do
    entry=$(printf '%s' "$entry" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [[ -z "$entry" ]] && continue
    [[ "$app_lc" == *"$entry"* ]] && return 0
  done
  return 1
}

latest_event_epoch() {
  # Activity = most recent mouse/keyboard input while a coding app is
  # frontmost. Watching a long Claude turn keeps the streak alive (as
  # long as you move the mouse occasionally); clicking over to email
  # for a few minutes does not. Past idle_threshold_minutes in a
  # non-coding app registers as a real break.
  local idle now
  idle=$(user_idle_seconds); idle=${idle:-0}
  now=$(date +%s)
  if in_coding_app; then
    echo $(( now - idle ))
  else
    echo 0
  fi
}

send_notification() {
  # Platform-agnostic banner notification. Preference order:
  #   1. terminal-notifier (macOS, brew install terminal-notifier) —
  #      reliable, has its own app bundle so Notification Center honors
  #      it without the Script Editor permission quirk.
  #   2. osascript (macOS built-in) — works only if the user has granted
  #      "Script Editor" notification permission in System Settings.
  #   3. notify-send (Linux libnotify).
  # Pass urgency=urgent as the third arg to use a more jarring sound and
  # pierce Do Not Disturb (where the notifier supports it).
  local title="$1" body="$2" urgency="${3:-normal}"
  local sound="Glass"
  [[ "$urgency" == "urgent" ]] && sound="Basso"
  if command -v terminal-notifier >/dev/null 2>&1; then
    local flags=(-title "$title" -message "$body" -sound "$sound")
    [[ "$urgency" == "urgent" ]] && flags+=(-ignoreDnD)
    terminal-notifier "${flags[@]}" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    local t="${title//\\/\\\\}"; t="${t//\"/\\\"}"
    local b="${body//\\/\\\\}";  b="${b//\"/\\\"}"
    osascript -e "display notification \"${b}\" with title \"${t}\" sound name \"${sound}\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    local urgency_flag=()
    [[ "$urgency" == "urgent" ]] && urgency_flag=(--urgency=critical)
    notify-send "${urgency_flag[@]}" "$title" "$body" >/dev/null 2>&1 || true
  fi
}

notify() {
  local mins="$1" tier="$2"
  local title body urgency="normal"
  title=$(render_template "$(yaml_get "${tier}_notification_title")" "$mins")
  body=$(render_template  "$(yaml_get "${tier}_notification_body")"  "$mins")
  [[ "$tier" == "hard_block" ]] && urgency="urgent"
  send_notification "$title" "$body" "$urgency"
}

write_nudge() {
  local mins="$1" tier="$2" key body
  case "$tier" in
    gentle)     key=gentle_nudge ;;
    firm)       key=firm_nudge ;;
    hard_block) key=hard_block_message ;;
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
  else echo '{"last_event":0,"streak_start":0,"last_notified":0,"last_release":0}'
  fi
}

write_state() {
  printf '{"last_event":%s,"streak_start":%s,"last_notified":%s,"last_release":%s}\n' \
    "$1" "$2" "$3" "$4" > "$STATE_FILE"
}

plog "monitor started (pid=$$, streak_limit=${STREAK_LIMIT}s, idle=${IDLE_THRESHOLD}s, poll=${POLL_INTERVAL}s)"
[[ -f "$NUDGE_FILE" ]] || clear_nudge

while true; do
  now=$(date +%s)
  latest=$(latest_event_epoch); latest=${latest:-0}

  state=$(read_state)
  last_event=$(echo "$state" | jq -r '.last_event')
  streak_start=$(echo "$state" | jq -r '.streak_start')
  last_notified=$(echo "$state" | jq -r '.last_notified')
  last_release=$(echo "$state" | jq -r '.last_release // 0')

  if (( latest > last_event )); then
    gap=$(( latest - last_event ))
    if (( last_event == 0 || gap > IDLE_THRESHOLD )); then
      if (( last_event > 0 )); then
        streak_len=$(( last_event - streak_start ))
        slog "break_end prior_streak_min=$(( streak_len / 60 )) gap_min=$(( gap / 60 ))"
        # If the prior streak had crossed at least the gentle threshold,
        # this break is a real "release" — log + notify so the user
        # knows they are unblocked.
        if (( streak_len >= STREAK_LIMIT )); then
          last_release=$now
          slog "release prior_streak_min=$(( streak_len / 60 ))"
          send_notification "Claude Code: break registered" "You're unblocked. Welcome back."
        fi
      fi
      streak_start=$latest
      clear_nudge
    fi
    last_event=$latest
  fi

  # Currently coding = last event is within idle threshold of now.
  if (( last_event > 0 )) && (( now - last_event < IDLE_THRESHOLD )); then
    active_streak=$(( now - streak_start ))
    tier=""
    if   (( active_streak >= HARD_BLOCK_THRESHOLD )); then tier=hard_block
    elif (( active_streak >= FIRM_THRESHOLD ));       then tier=firm
    elif (( active_streak >= STREAK_LIMIT ));         then tier=gentle
    fi
    if [[ -n "$tier" ]]; then
      mins=$(( active_streak / 60 ))
      write_nudge "$mins" "$tier"
      if (( now - last_notified >= NOTIFY_COOLDOWN )); then
        notify "$mins" "$tier"
        slog "nudged tier=${tier} streak_min=${mins}"
        last_notified=$now
      fi
    else
      clear_nudge
    fi
  else
    # On a break right now — no nudge needed.
    clear_nudge
  fi

  write_state "$last_event" "$streak_start" "$last_notified" "$last_release"
  sleep "$POLL_INTERVAL"
done
