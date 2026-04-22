#!/usr/bin/env bash
# One-shot installer: registers hook.sh as a UserPromptSubmit hook in
# ~/.claude/settings.json (idempotent — won't duplicate) and, on macOS,
# installs a launchd plist so monitor.sh starts at login.
#
# Safe to re-run. Prints what it did; prompts before overwriting.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HOOK="$ROOT/hook.sh"
MONITOR="$ROOT/monitor.sh"
STATUSLINE="$ROOT/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"

command -v jq >/dev/null || { echo "error: jq is required (brew install jq / apt install jq)" >&2; exit 1; }
chmod +x "$HOOK" "$MONITOR" "$STATUSLINE" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

# --- Hook registration --------------------------------------------------
# Idempotent: only add if no hook with the same command already exists.
tmp=$(mktemp)
jq --arg cmd "$HOOK" '
  .hooks //= {} |
  .hooks.UserPromptSubmit //= [] |
  if any(.hooks.UserPromptSubmit[]?; .hooks[]?.command == $cmd)
  then .
  else .hooks.UserPromptSubmit += [{"hooks": [{"type": "command", "command": $cmd}]}]
  end
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "✓ hook registered in $SETTINGS"

# --- Statusline (widget showing current streak) ------------------------
# Only install if the user doesn't already have a statusLine command.
existing_sl=$(jq -r '.statusLine.command // empty' "$SETTINGS")
if [[ -z "$existing_sl" ]]; then
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

# --- Background daemon --------------------------------------------------
case "$(uname)" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/com.user.claude-activity-monitor.plist"
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
    <key>StandardOutPath</key>          <string>$ROOT/data/monitor.log</string>
    <key>StandardErrorPath</key>        <string>$ROOT/data/monitor.log</string>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load   "$PLIST"
    echo "✓ launchd agent installed ($PLIST) — monitor will run at login"
    ;;
  Linux)
    UNIT="$HOME/.config/systemd/user/claude-activity-monitor.service"
    mkdir -p "$(dirname "$UNIT")"
    cat > "$UNIT" <<EOF
[Unit]
Description=Claude Code break monitor

[Service]
Type=simple
ExecStart=$MONITOR
WorkingDirectory=$ROOT
Restart=always

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now claude-activity-monitor.service
    echo "✓ systemd user unit installed ($UNIT) — monitor is running"
    ;;
  *)
    echo "note: automatic daemon setup not supported on $(uname); start manually with:"
    echo "      nohup $MONITOR >/dev/null 2>&1 & disown"
    ;;
esac

# --- Post-install smoke checks ------------------------------------------
# Catch the common "install said OK but nothing actually works" class of
# bugs. Re-runnable: just re-run install.sh, it's idempotent.
echo
echo "Verifying:"
fail=0

# Daemon is up. Give launchd/systemd a moment to spawn the process.
for _ in 1 2 3 4 5; do
  pgrep -f "$MONITOR" >/dev/null 2>&1 && break
  sleep 0.2
done
if pgrep -f "$MONITOR" >/dev/null 2>&1; then
  echo "  ✓ monitor is running"
else
  echo "  ✗ monitor is NOT running — try: nohup $MONITOR >/dev/null 2>&1 & disown"
  fail=1
fi

# Hook is in settings.json.
if jq -e --arg cmd "$HOOK" \
  'any(.hooks.UserPromptSubmit[]?; .hooks[]?.command == $cmd)' \
  "$SETTINGS" >/dev/null; then
  echo "  ✓ hook registered in $SETTINGS"
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
