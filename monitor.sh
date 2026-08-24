#!/usr/bin/env bash
# Continuously monitors Claude Code activity and nudges the user to take
# a break. The activity signal is data/last_prompt.ts — hook.sh touches
# it on every UserPromptSubmit, so only real user prompts count
# (mouse movement, typing outside Claude Code, background agents,
# autonomous loops, and Claude's own tool use do not).
#
#   private (gitignored)  -> data/state.json, data/monitor.log, data/last_prompt.ts
#   shareable (committed) -> stats/activity.log, stats/active.txt
#
# stats/active.txt holds the currently-active tier (nudge or block) and
# its message body. It's read by the Claude Code hook (hook.sh) on every
# user prompt; when non-empty, its contents get injected as context or
# refuse the prompt outright. If the user manually deletes
# stats/active.txt the monitor interprets that as "I'm taking a break
# now, reset" and sets streak_start to now on the next poll.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$ROOT/data"
STATS_DIR="$ROOT/stats"
CONFIG="$ROOT/config.yaml"
mkdir -p "$DATA_DIR" "$STATS_DIR"

STATE_FILE="$DATA_DIR/state.json"
PRIVATE_LOG="$DATA_DIR/monitor.log"
PUBLIC_LOG="$STATS_DIR/activity.log"
ACTIVE_FILE="$STATS_DIR/active.txt"
LAST_PROMPT_FILE="$DATA_DIR/last_prompt.ts"
# Liveness beacon, touched every poll. hook.sh and statusline.sh check
# it to decide whether active.txt is trustworthy. Keying that off
# active.txt's own mtime (the old approach) silently disarmed every
# block three minutes after it fired, because the monitor only rewrites
# active.txt on tier transitions.
HEARTBEAT_FILE="$DATA_DIR/monitor.heartbeat"

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

mtime() {
  # Portable file mtime in epoch seconds. Try GNU/Linux (`stat -c %Y`)
  # first — on Linux, `stat -f` silently prints filesystem info
  # (success exit, junk output) which would poison downstream
  # arithmetic. macOS falls through to `stat -f %m`.
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

# Thresholds are re-read whenever config.yaml changes, so edits (by hand
# or by the post-break prompt) take effect on the next poll instead of
# needing a daemon restart.
CONFIG_MTIME=""
load_config() {
  POLL_INTERVAL=$(yaml_int poll_interval_seconds)
  IDLE_THRESHOLD=$(( $(yaml_int idle_threshold_minutes) * 60 ))
  NUDGE_THRESHOLD=$(( $(yaml_int nudge_minutes) * 60 ))
  BLOCK_THRESHOLD=$(( $(yaml_int block_minutes) * 60 ))
  NOTIFY_COOLDOWN=$(( $(yaml_int notify_cooldown_minutes) * 60 ))
  CONFIG_MTIME=$(mtime "$CONFIG")
}
load_config

# Substitute {mins}, {idle_min}, {nudge_min} placeholders.
render_template() {
  local tpl="$1" mins="$2" remaining="${3:-}"
  local idle_min=$(( IDLE_THRESHOLD / 60 ))
  local nudge_min=$(( NUDGE_THRESHOLD / 60 ))
  # {remaining} = whole minutes of enforced break still to serve.
  # Defaults to a full break so templates render sensibly at the moment
  # the block first fires.
  [[ -n "$remaining" ]] || remaining=$idle_min
  tpl=${tpl//\{mins\}/$mins}
  tpl=${tpl//\{idle_min\}/$idle_min}
  tpl=${tpl//\{nudge_min\}/$nudge_min}
  tpl=${tpl//\{remaining\}/$remaining}
  printf '%s' "$tpl"
}

plog() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PRIVATE_LOG"; }
slog() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PUBLIC_LOG"; }

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

play_audio() {
  # Fire-and-forget audio clip. Called at tier transitions alongside
  # the OS banner so the user gets an unmissable "heads up, thing
  # just happened" signal. Empty path is the off switch. Path can
  # be absolute or relative to the repo root.
  local path="$1"
  [[ -z "$path" ]] && return 0
  [[ "$path" = /* ]] || path="$ROOT/$path"
  [[ -f "$path" ]] || { plog "audio file not found: $path"; return 0; }
  if command -v afplay >/dev/null 2>&1; then
    afplay "$path" >/dev/null 2>&1 &
  elif command -v paplay >/dev/null 2>&1; then
    paplay "$path" >/dev/null 2>&1 &
  elif command -v aplay >/dev/null 2>&1; then
    aplay "$path" >/dev/null 2>&1 &
  fi
}

notify() {
  # All break-monitor notifications pass urgency=urgent so they pierce
  # Do Not Disturb / Focus modes. The whole point of this tool is to
  # tell the user things they would otherwise ignore.
  local mins="$1" tier="$2" remaining="${3:-}"
  local title body
  title=$(render_template "$(yaml_get "${tier}_notification_title")" "$mins" "$remaining")
  body=$(render_template  "$(yaml_get "${tier}_notification_body")"  "$mins" "$remaining")
  send_notification "$title" "$body" urgent
  play_audio "$(yaml_get "${tier}_audio_file")"
}

# --- Post-break prompt ---------------------------------------------
# When an enforced break ends, ask the user for the next round's numbers
# and write them into config.yaml. The poll loop notices the config
# mtime change and reloads, so new values take effect immediately.
#
# Always invoked detached (`ask_new_numbers ... &`) — a dialog sitting
# on screen must never wedge the monitor loop.

# One text-input dialog. Echoes what was typed, or nothing if the user
# cancelled, dismissed, or let it time out.
ask_dialog() {
  local prompt="$1" default="$2"
  local p=${prompt//\\/\\\\}; p=${p//\"/\\\"}
  # AppleScript string literals cannot span lines — splice real newlines
  # into `" & return & "` so multi-line prompts render.
  p=${p//$'\n'/\" \& return \& \"}
  osascript 2>/dev/null <<OSA
try
  set r to display dialog "$p" default answer "$default" with title "Claude Code: break over" buttons {"Keep current", "Set"} default button "Set" giving up after 120
  if gave up of r then return ""
  if button returned of r is not "Set" then return ""
  return text returned of r
on error
  return ""
end try
OSA
}

# Rewrite a top-level `key: value` line in config.yaml, preserving any
# trailing comment. Only touches integer threshold keys.
set_config_int() {
  local key="$1" val="$2" tmp="$CONFIG.tmp.$$"
  awk -v k="$key" -v v="$val" '
    $0 ~ "^"k":" {
      comment = ""
      if (match($0, /#.*/)) comment = "    " substr($0, RSTART)
      printf "%s: %s%s\n", k, v, comment
      next
    }
    { print }
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
}

ask_new_numbers() {
  local streak_min="$1"
  local cur_block=$(( BLOCK_THRESHOLD / 60 ))
  local cur_break=$(( IDLE_THRESHOLD / 60 ))
  local new_block new_break new_nudge

  new_block=$(ask_dialog "Break over. That round was ${streak_min} minutes of coding.

Make me stop after how many minutes next time?" "$cur_block")
  if ! [[ "$new_block" =~ ^[0-9]+$ ]] || (( new_block < 5 || new_block > 600 )); then
    plog "post-break prompt: no valid stop-after answer, keeping ${cur_block}m"
    return 0
  fi

  new_break=$(ask_dialog "And how long should that break be?" "$cur_break")
  if ! [[ "$new_break" =~ ^[0-9]+$ ]] || (( new_break < 1 || new_break > 240 )); then
    plog "post-break prompt: no valid break-length answer, keeping ${cur_break}m"
    new_break=$cur_break
  fi

  # Gentle reminders start halfway to the hard stop.
  new_nudge=$(( new_block / 2 ))
  (( new_nudge < 1 )) && new_nudge=1

  set_config_int block_minutes "$new_block"
  set_config_int nudge_minutes "$new_nudge"
  set_config_int idle_threshold_minutes "$new_break"
  plog "post-break prompt: block=${new_block}m nudge=${new_nudge}m break=${new_break}m"
  slog "reconfigured block_min=${new_block} nudge_min=${new_nudge} break_min=${new_break}"
  refresh_menubar
}

# Fire-and-forget SwiftBar refresh so the menubar reflects a tier
# change immediately instead of waiting on its ~1-min polling cadence
# (filename convention is *.1m.sh). Without this, the OS banner fires
# on the tier flip but the menubar sits stale until the next refresh.
refresh_menubar() {
  [[ "$(uname)" == "Darwin" ]] || return
  /usr/bin/open -g 'swiftbar://refreshallplugins' >/dev/null 2>&1 &
}

write_nudge() {
  local mins="$1" tier="$2" remaining="${3:-}" key body
  case "$tier" in
    nudge) key=nudge_instructions ;;
    block) key=block_message ;;
    *) return ;;
  esac
  body=$(render_template "$(yaml_get "$key")" "$mins" "$remaining")
  {
    printf 'TIER=%s\n' "$tier"
    printf '%s\n' "$body"
  } > "$ACTIVE_FILE"
  refresh_menubar
}

# No-op when active.txt is already empty. Without this guard the idle
# path truncated the file and kicked a SwiftBar refresh on every single
# poll, spawning an `open -g` process every 30 seconds forever.
clear_nudge() {
  [[ -f "$ACTIVE_FILE" && ! -s "$ACTIVE_FILE" ]] && return 0
  : > "$ACTIVE_FILE"
  refresh_menubar
}

read_state() {
  if [[ -f "$STATE_FILE" ]]; then cat "$STATE_FILE"
  else echo '{"last_event":0,"streak_start":0,"last_notified":0,"last_release":0,"last_tier":"","block_start":0}'
  fi
}

# last_tier is the most recent tier the monitor wrote to active.txt
# ("nudge"/"block", or "" if the file was cleared). Lets the loop
# distinguish "monitor cleared the active tier" (we set last_tier="")
# from "user manually deleted active.txt to request a reset"
# (last_tier still non-empty but active.txt is gone).
# block_start is the epoch second the block tier fired. The enforced
# break is measured from it, not from the user's last prompt.
write_state() {
  printf '{"last_event":%s,"streak_start":%s,"last_notified":%s,"last_release":%s,"last_tier":"%s","block_start":%s}\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" > "$STATE_FILE"
}

plog "monitor started (pid=$$, nudge=${NUDGE_THRESHOLD}s, block=${BLOCK_THRESHOLD}s, idle=${IDLE_THRESHOLD}s, poll=${POLL_INTERVAL}s)"
[[ -f "$ACTIVE_FILE" ]] || clear_nudge

while true; do
  now=$(date +%s)
  # Liveness beacon first: hook.sh refuses to enforce anything unless
  # this file is fresh, so it must be written before any tier logic.
  : > "$HEARTBEAT_FILE"
  # Pick up config.yaml edits without a restart.
  if [[ "$(mtime "$CONFIG")" != "$CONFIG_MTIME" ]]; then
    load_config
    plog "config reloaded (nudge=${NUDGE_THRESHOLD}s, block=${BLOCK_THRESHOLD}s, idle=${IDLE_THRESHOLD}s)"
    slog "config_reload nudge_min=$(( NUDGE_THRESHOLD / 60 )) block_min=$(( BLOCK_THRESHOLD / 60 )) break_min=$(( IDLE_THRESHOLD / 60 ))"
  fi
  latest=$(latest_event_epoch); latest=${latest:-0}
  wrote_active=""

  state=$(read_state)
  # Use `// 0` / `// ""` on every field so a corrupt state.json never
  # propagates empty strings into the write_state printf (which would
  # produce invalid JSON like `"last_notified":,` and wedge the loop).
  last_event=$(echo "$state" | jq -r '.last_event // 0')
  streak_start=$(echo "$state" | jq -r '.streak_start // 0')
  last_notified=$(echo "$state" | jq -r '.last_notified // 0')
  last_release=$(echo "$state" | jq -r '.last_release // 0')
  last_tier=$(echo "$state" | jq -r '.last_tier // ""')
  block_start=$(echo "$state" | jq -r '.block_start // 0')
  # Belt and suspenders: if jq failed entirely (e.g. corrupt JSON
  # parse error), every variable is the string "null" or "". Coerce
  # all the numeric ones so arithmetic never sees "".
  [[ "$last_event"    =~ ^[0-9]+$ ]] || last_event=0
  [[ "$streak_start"  =~ ^[0-9]+$ ]] || streak_start=0
  [[ "$last_notified" =~ ^[0-9]+$ ]] || last_notified=0
  [[ "$last_release"  =~ ^[0-9]+$ ]] || last_release=0
  [[ "$block_start"   =~ ^[0-9]+$ ]] || block_start=0

  # Manual reset: user deleted/emptied active.txt while the monitor
  # believed a nudge was in effect. Treat as "I'm taking a break now"
  # — clear the streak, fire a release notification if the prior
  # streak was significant, and skip the rest of this poll.
  active_empty=0
  [[ ! -s "$ACTIVE_FILE" ]] && active_empty=1
  if [[ -n "$last_tier" ]] && (( active_empty == 1 )); then
    prior_streak=$(( last_event - streak_start ))
    (( prior_streak < 0 )) && prior_streak=0
    slog "manual_reset prior_streak_min=$(( prior_streak / 60 )) prior_tier=${last_tier}"
    if [[ "$last_tier" == "block" ]]; then
      last_release=$now
      send_notification "Claude Code: unblocked" "Manual reset. You can prompt again." urgent
      play_audio "$(yaml_get release_audio_file)"
    fi
    streak_start=$now
    last_event=$now
    last_tier=""
    block_start=0
    write_state "$last_event" "$streak_start" "$last_notified" "$last_release" "$last_tier" "$block_start"
    refresh_menubar
    sleep "$POLL_INTERVAL"
    continue
  fi

  # --- Enforced break hold -------------------------------------------
  # Once the block tier fires, hold it for a FULL idle_threshold measured
  # from the moment it fired. The old code measured the break from the
  # user's last prompt instead, so a block landing 9 minutes after their
  # last prompt released 1 minute later — a "10-minute break" that was
  # nothing of the sort. Blocked prompts never touch last_prompt.ts, so
  # nothing the user does in Claude Code can extend or shorten this.
  if [[ "$last_tier" == "block" ]] && (( block_start > 0 )); then
    block_mins=$(( (block_start - streak_start) / 60 ))
    (( block_mins < 0 )) && block_mins=0
    if (( now - block_start < IDLE_THRESHOLD )); then
      remaining=$(( (IDLE_THRESHOLD - (now - block_start) + 59) / 60 ))
      if (( now - last_notified >= NOTIFY_COOLDOWN )); then
        notify "$block_mins" block "$remaining"
        slog "blocked streak_min=${block_mins} break_remaining_min=${remaining}"
        last_notified=$now
      fi
      write_state "$last_event" "$streak_start" "$last_notified" "$last_release" "$last_tier" "$block_start"
      sleep "$POLL_INTERVAL"
      continue
    fi
    # Break fully served — release.
    last_release=$now
    slog "break_end prior_streak_min=${block_mins} prior_tier=block"
    slog "release prior_streak_min=${block_mins}"
    send_notification "Claude Code: unblocked" "Break registered. You can prompt again." urgent
    play_audio "$(yaml_get release_audio_file)"
    clear_nudge
    last_tier=""
    block_start=0
    streak_start=$now
    last_event=$now
    write_state "$last_event" "$streak_start" "$last_notified" "$last_release" "$last_tier" "$block_start"
    ask_new_numbers "$block_mins" &
    sleep "$POLL_INTERVAL"
    continue
  fi

  if (( latest > last_event )); then
    gap=$(( latest - last_event ))
    if (( last_event == 0 || gap > IDLE_THRESHOLD )); then
      if (( last_event > 0 )); then
        streak_len=$(( last_event - streak_start ))
        slog "break_end prior_streak_min=$(( streak_len / 60 )) gap_min=$(( gap / 60 )) prior_tier=${last_tier}"
        # Only block-tier streaks trigger a release ping. Nudge
        # idle-crossings don't: the user just wants to know when
        # a refusal has lifted, not every time they step away
        # mid-nudge. (Normally the idle-crossing branch below
        # fires the release *while* the user is still away, but
        # we keep this path too for the edge case where the poll
        # cadence races the user's return prompt.)
        if [[ "$last_tier" == "block" ]]; then
          last_release=$now
          slog "release prior_streak_min=$(( streak_len / 60 ))"
          send_notification "Claude Code: unblocked" "Break registered. You can prompt again." urgent
          play_audio "$(yaml_get release_audio_file)"
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
      # Only rewrite active.txt on tier transitions. Rewriting every
      # poll causes two problems: different Claude Code sessions
      # prompting seconds apart see different {mins} values, and the
      # mtime churn breaks any "fire once per tier-epoch" gating the
      # hook might want to do. Freeze the message at the moment the
      # tier flips; it stays stable until the next transition.
      if [[ "$last_tier" != "$tier" ]]; then
        write_nudge "$mins" "$tier"
        last_tier=$tier
        wrote_active=1
        # Stamp when the block landed; the enforced break runs from here.
        [[ "$tier" == "block" ]] && block_start=$now
      fi
      if (( now - last_notified >= NOTIFY_COOLDOWN )); then
        notify "$mins" "$tier"
        slog "nudged tier=${tier} streak_min=${mins}"
        last_notified=$now
        # Re-arm the in-chat nudge on the same cadence as the banner.
        # hook.sh injects at most once per active.txt mtime, and the
        # monitor only rewrote active.txt on tier flips — so a streak
        # sitting in nudge tier for an hour produced exactly ONE poem.
        # Rewriting here gives a fresh reminder every cooldown, with the
        # current streak length.
        [[ "$tier" == "nudge" && -z "$wrote_active" ]] && write_nudge "$mins" "$tier"
      fi
    else
      clear_nudge
      last_tier=""
    fi
  else
    # On a break right now — no nudge needed. If we were in a tier
    # on the prior poll and the streak was long enough to matter,
    # fire the release exactly once at the moment the idle timer
    # crossed the threshold (not on the next prompt — the user
    # wants to hear "break registered" while they're still away,
    # not when they come back).
    if [[ -n "$last_tier" ]]; then
      prior_streak=$(( last_event - streak_start ))
      (( prior_streak < 0 )) && prior_streak=0
      slog "break_end prior_streak_min=$(( prior_streak / 60 )) prior_tier=${last_tier}"
      # Release sound only fires on BLOCK lift — the one moment
      # that actually matters (the refusal has stopped). Firing on
      # every nudge-tier idle crossing would ping the user every
      # time they step away for a few minutes mid-session, which
      # is noise, not signal.
      if [[ "$last_tier" == "block" ]]; then
        last_release=$now
        slog "release prior_streak_min=$(( prior_streak / 60 ))"
        send_notification "Claude Code: unblocked" "Break registered. You can prompt again." urgent
        play_audio "$(yaml_get release_audio_file)"
      fi
      # Pre-seed last_event so the "user prompted after idle gap"
      # path in the next poll doesn't *also* fire a second release
      # for the same streak. The next real prompt will update
      # last_event normally via the latest-mtime read.
      last_event=$now
      streak_start=$now
    fi
    clear_nudge
    last_tier=""
  fi

  write_state "$last_event" "$streak_start" "$last_notified" "$last_release" "$last_tier" "$block_start"
  sleep "$POLL_INTERVAL"
done
