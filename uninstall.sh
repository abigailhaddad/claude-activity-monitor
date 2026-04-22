#!/usr/bin/env bash
# Removes everything install.sh put in place: launchd agent, the
# UserPromptSubmit hook, the SwiftBar plugin symlink, and (only if
# it still points at ours) the statusLine entry in
# ~/.claude/settings.json. Leaves config.yaml, state.json, and the
# repo itself alone — delete the repo manually for a full cleanup.
#
# Safe to re-run.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
HOOK="$ROOT/hook.sh"
STATUSLINE="$ROOT/statusline.sh"
MONITOR="$ROOT/monitor.sh"
SETTINGS="$HOME/.claude/settings.json"

echo "Uninstalling claude-activity-monitor"

# --- Stop and remove the launchd agent ---------------------------------
PLIST="$HOME/Library/LaunchAgents/com.user.claude-activity-monitor.plist"
if [[ -f "$PLIST" ]]; then
  launchctl bootout "gui/$(id -u)/com.user.claude-activity-monitor" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "  ✓ launchd agent removed ($PLIST)"
else
  echo "  · no launchd agent to remove"
fi

# Kill any still-running monitor process (e.g. one started manually).
if pgrep -f "$MONITOR" >/dev/null 2>&1; then
  pkill -f "$MONITOR" 2>/dev/null || true
  echo "  ✓ running monitor process killed"
fi

# --- SwiftBar plugin symlink -------------------------------------------
SWIFTBAR_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null \
  || echo "$HOME/Library/Application Support/SwiftBar/Plugins")
SWIFTBAR_PLUGIN="$SWIFTBAR_DIR/claude-activity-monitor.1m.sh"
if [[ -L "$SWIFTBAR_PLUGIN" ]]; then
  rm -f "$SWIFTBAR_PLUGIN"
  echo "  ✓ SwiftBar plugin symlink removed ($SWIFTBAR_PLUGIN)"
  # Nudge SwiftBar to refresh so the stale item disappears from the menubar.
  open "swiftbar://refreshallplugins" 2>/dev/null || true
fi

# --- Settings.json surgery ---------------------------------------------
if [[ -f "$SETTINGS" ]]; then
  command -v jq >/dev/null || { echo "error: jq is required to edit $SETTINGS" >&2; exit 1; }

  # Remove our hook entry from every event section it's in
  # (UserPromptSubmit + Stop), dropping now-empty groups + sections.
  tmp=$(mktemp)
  jq --arg cmd "$HOOK" '
    def strip(event):
      if .hooks[event] then
        .hooks[event] |= (
          map(.hooks |= map(select(.command != $cmd))
              | select(.hooks | length > 0))
        )
        | if .hooks[event] == [] then del(.hooks[event]) else . end
      else . end;
    strip("UserPromptSubmit")
    | strip("Stop")
    | if .hooks == {} then del(.hooks) else . end
  ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  echo "  ✓ hooks removed from $SETTINGS"

  # Remove statusLine only if it still points at ours.
  existing_sl=$(jq -r '.statusLine.command // empty' "$SETTINGS")
  if [[ "$existing_sl" == "$STATUSLINE" ]]; then
    tmp=$(mktemp)
    jq 'del(.statusLine)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    echo "  ✓ statusline entry removed"
  elif [[ -n "$existing_sl" ]]; then
    echo "  · statusLine points at $existing_sl (not ours) — leaving it alone"
  fi
else
  echo "  · no $SETTINGS to edit"
fi

echo
echo "Done. Your repo directory ($ROOT) is untouched — delete it if you want:"
echo "  rm -rf \"$ROOT\""
