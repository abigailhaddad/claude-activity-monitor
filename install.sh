#!/usr/bin/env bash
# One-shot installer: registers hook.sh as a UserPromptSubmit hook in
# ~/.claude/settings.json (idempotent — won't duplicate) and installs
# a launchd plist so monitor.sh starts at login.
#
# Safe to re-run. macOS only.

set -euo pipefail

[[ "$(uname)" == "Darwin" ]] || {
  echo "error: macOS only (the menubar widget is a SwiftBar plugin, which is Mac-only)" >&2
  exit 1
}

ROOT="$(cd "$(dirname "$0")" && pwd)"
HOOK="$ROOT/hook.sh"
MONITOR="$ROOT/monitor.sh"
STATUSLINE="$ROOT/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"

CONFIG="$ROOT/config.yaml"

command -v jq >/dev/null || { echo "error: jq is required (brew install jq)" >&2; exit 1; }
chmod +x "$HOOK" "$MONITOR" "$STATUSLINE" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

# --- Interactive config (only when run from a TTY) ---------------------
# When piped into — `curl ... | sh` — stdin is not a TTY, so we skip the
# prompts and use whatever is already in config.yaml.
if [[ -t 0 ]]; then
  cur_nudge=$(sed -nE 's/^nudge_minutes:[[:space:]]*([0-9]+).*/\1/p' "$CONFIG")
  cur_block=$(sed -nE 's/^block_minutes:[[:space:]]*([0-9]+).*/\1/p' "$CONFIG")
  cur_idle=$(sed -nE 's/^idle_threshold_minutes:[[:space:]]*([0-9]+).*/\1/p' "$CONFIG")
  cur_audio="N"
  grep -qE '^(nudge|block|release)_audio_file:[[:space:]]*"[^"]+"' "$CONFIG" && cur_audio="Y"

  echo "Configure (hit Enter to accept the shown default):"
  read -rp "  Nudge tier fires at [$cur_nudge] minutes of coding: " in_nudge
  read -rp "  Block tier fires at [$cur_block] minutes of coding: " in_block
  read -rp "  Break length required to reset [$cur_idle] minutes: " in_idle
  read -rp "  Play audio at block / break-end? [$cur_audio/n]: " in_audio

  new_nudge=${in_nudge:-$cur_nudge}
  new_block=${in_block:-$cur_block}
  new_idle=${in_idle:-$cur_idle}

  # Integer-validate; silently keep current if the user typed garbage.
  [[ "$new_nudge" =~ ^[0-9]+$ ]] || new_nudge=$cur_nudge
  [[ "$new_block" =~ ^[0-9]+$ ]] || new_block=$cur_block
  [[ "$new_idle"  =~ ^[0-9]+$ ]] || new_idle=$cur_idle

  # Normalize audio answer. Empty = accept default. n/N/no → off.
  want_audio_on=1
  case "${in_audio:-}" in
    ""|y|Y|yes|YES) [[ "$cur_audio" == "Y" ]] && want_audio_on=1 || want_audio_on=0 ;;
    n|N|no|NO)      want_audio_on=0 ;;
    *)              [[ "$cur_audio" == "Y" ]] && want_audio_on=1 || want_audio_on=0 ;;
  esac

  tmp=$(mktemp)
  sed -E \
    -e "s|^nudge_minutes:[[:space:]]*[0-9]+.*|nudge_minutes: $new_nudge|" \
    -e "s|^block_minutes:[[:space:]]*[0-9]+.*|block_minutes: $new_block|" \
    -e "s|^idle_threshold_minutes:[[:space:]]*[0-9]+.*|idle_threshold_minutes: $new_idle|" \
    "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

  if (( want_audio_on == 0 )); then
    tmp=$(mktemp)
    sed -E 's|^(nudge_audio_file|block_audio_file|release_audio_file):.*|\1: ""|' \
      "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  else
    # Restore the shipped defaults if the user previously turned audio
    # off and is now turning it back on. Only touch block/release —
    # nudge ships silent.
    tmp=$(mktemp)
    sed -E \
      -e 's|^block_audio_file:.*|block_audio_file: "assets/block.mp3"|' \
      -e 's|^release_audio_file:.*|release_audio_file: "assets/release.mp3"|' \
      "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  fi
  echo
fi

# --- Hook registration --------------------------------------------------
# Idempotent: only add if no hook with the same command already exists.
# We register only UserPromptSubmit. Stop was registered here in an
# earlier version to catch interjections and long tool runs as
# "engagement," but treating response-end as activity meant a user
# who walked away mid-stream never accumulated idle time. Now only
# actual user prompts count. Also strips any stale Stop entry from a
# previous install.
tmp=$(mktemp)
jq --arg cmd "$HOOK" '
  .hooks //= {}
  | .hooks.UserPromptSubmit //= []
  | if any(.hooks.UserPromptSubmit[]?; .hooks[]?.command == $cmd) | not
    then .hooks.UserPromptSubmit += [{"hooks": [{"type": "command", "command": $cmd}]}]
    else . end
  | if .hooks.Stop then
      .hooks.Stop = (.hooks.Stop | map(select(.hooks | any(.command == $cmd) | not)))
      | if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end
    else . end
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "✓ hook (UserPromptSubmit) registered in $SETTINGS"

# --- Statusline (Claude Code statusLine widget) ------------------------
# Only install if the user doesn't already have a statusLine and
# doesn't already have the SwiftBar menubar plugin symlinked. The
# menubar plugin is the preferred surface (live countdown, always
# visible) — the Claude Code statusLine is the fallback for folks
# who don't want to install SwiftBar. If both are active the same
# number shows up in two places, which is clutter.
# SwiftBar's plugin folder can be relocated — read the user's
# choice instead of hard-coding the default. If SwiftBar isn't
# installed the defaults read fails and we fall back to the default.
SWIFTBAR_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null \
  || echo "$HOME/Library/Application Support/SwiftBar/Plugins")
SWIFTBAR_PLUGIN="$SWIFTBAR_DIR/claude-activity-monitor.1m.sh"
existing_sl=$(jq -r '.statusLine.command // empty' "$SETTINGS")
if [[ -L "$SWIFTBAR_PLUGIN" || -f "$SWIFTBAR_PLUGIN" ]]; then
  echo "· SwiftBar plugin detected at $SWIFTBAR_PLUGIN — skipping Claude Code statusLine"
  # Also strip a stale registration from a previous (pre-SwiftBar) install.
  if [[ "$existing_sl" == "$STATUSLINE" ]]; then
    tmp=$(mktemp)
    jq 'del(.statusLine)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    echo "  (removed stale .statusLine pointing at our script)"
  fi
elif [[ -z "$existing_sl" ]]; then
  tmp=$(mktemp)
  jq --arg cmd "$STATUSLINE" '.statusLine = {"type": "command", "command": $cmd}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "✓ statusline widget registered (current streak shown in Claude Code)"
elif [[ "$existing_sl" == "$STATUSLINE" ]]; then
  echo "✓ statusline widget already registered"
else
  echo "note: you already have a statusLine command ($existing_sl) — leaving it alone."
  echo "      to use the break-monitor widget instead, edit $SETTINGS and set"
  echo "      .statusLine.command to: $STATUSLINE"
fi

# --- Background daemon (launchd) ---------------------------------------
PLIST="$HOME/Library/LaunchAgents/com.user.claude-activity-monitor.plist"
# launchd's stdout/stderr paths must live OUTSIDE ~/Documents/ —
# macOS TCC/sandbox denies xpcproxy read-data on user folders it
# treats as sensitive (Documents, Desktop, Downloads), which
# manifests as posix_spawn "Operation not permitted" (exit 78,
# EX_CONFIG) in system logs. ~/Library/Logs/ is the conventional
# safe location. The monitor's own plog() log still writes to
# $ROOT/data/monitor.log — that runs as the user process, not
# launchd, and isn't subject to the spawn-time sandbox.
LAUNCHD_LOG="$HOME/Library/Logs/claude-activity-monitor.log"
mkdir -p "$(dirname "$LAUNCHD_LOG")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>                    <string>com.user.claude-activity-monitor</string>
    <key>ProgramArguments</key>         <array><string>$MONITOR</string></array>
    <key>WorkingDirectory</key>         <string>$ROOT</string>
    <key>RunAtLoad</key>                <true/>
    <key>KeepAlive</key>                <true/>
    <key>StandardOutPath</key>          <string>$LAUNCHD_LOG</string>
    <key>StandardErrorPath</key>        <string>$LAUNCHD_LOG</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>                 <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
</dict>
</plist>
EOF
# Prefer bootout/bootstrap (modern launchctl) over load/unload
# (deprecated); old syntax also fails if the service is already in
# "spawn scheduled" state from a prior EX_CONFIG loop.
launchctl bootout "gui/$(id -u)/com.user.claude-activity-monitor" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "✓ launchd agent installed ($PLIST) — monitor will run at login"

# --- Post-install smoke checks ------------------------------------------
# Catch the common "install said OK but nothing actually works" class of
# bugs. Re-runnable: just re-run install.sh, it's idempotent.
echo
echo "Verifying:"
fail=0

# Daemon is up. launchd reload can take a couple of seconds on a
# first-run permission prompt, so wait up to ~3s.
for _ in $(seq 1 30); do
  pgrep -f "$MONITOR" >/dev/null 2>&1 && break
  sleep 0.1
done
if pgrep -f "$MONITOR" >/dev/null 2>&1; then
  echo "  ✓ monitor is running"
else
  echo "  ✗ monitor is NOT running — try: nohup $MONITOR >/dev/null 2>&1 & disown"
  fail=1
fi

# Hook is in settings.json (UserPromptSubmit only).
if jq -e --arg cmd "$HOOK" '
    any(.hooks.UserPromptSubmit[]?; .hooks[]?.command == $cmd)
  ' "$SETTINGS" >/dev/null; then
  echo "  ✓ hook (UserPromptSubmit) registered in $SETTINGS"
else
  echo "  ✗ hook NOT registered in $SETTINGS"
  fail=1
fi

# Statusline produces output.
sl_out=$(bash "$STATUSLINE" </dev/null 2>&1 || true)
if [[ -n "$sl_out" ]]; then
  echo "  ✓ statusline renders: $sl_out"
else
  echo "  ✗ statusline produced no output — check $STATUSLINE"
  fail=1
fi

echo
if (( fail == 0 )); then
  echo "All checks passed. Open a new Claude Code session and start prompting —"
  echo "nudge fires at $(sed -nE 's/^nudge_minutes:[[:space:]]*([0-9]+).*/\1/p' "$ROOT/config.yaml") minutes (edit config.yaml to change)."
else
  echo "Some checks failed — see above. Re-run ./install.sh after fixing,"
  echo "or ./uninstall.sh to back out."
  exit 1
fi
