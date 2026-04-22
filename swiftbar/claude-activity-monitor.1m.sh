#!/usr/bin/env bash
# SwiftBar plugin — live break-monitor readout in the Mac menubar.
#
# Filename convention: *.1m.sh tells SwiftBar to run this every 1
# minute. The plugin's stdout becomes the menubar title + dropdown.
#
# Install (symlink so edits to the repo take effect immediately):
#   mkdir -p "$HOME/Library/Application Support/SwiftBar/Plugins"
#   ln -sfn "$PWD/swiftbar/claude-activity-monitor.1m.sh" \
#     "$HOME/Library/Application Support/SwiftBar/Plugins/"
#
# Requires SwiftBar (brew install --cask swiftbar). BitBar / xbar
# use the same plugin format and should also work.

# Resolve through the symlink SwiftBar invokes us by, so we can
# still find the repo.
SELF="$0"
while [[ -L "$SELF" ]]; do
  link="$(readlink "$SELF")"
  [[ "$link" = /* ]] && SELF="$link" || SELF="$(dirname "$SELF")/$link"
done
REPO="$(cd "$(dirname "$SELF")/.." && pwd)"

# Single source of truth: reuse the Claude Code statusline renderer.
# Its stdin-drain behavior is compatible with SwiftBar's empty stdin.
line=$("$REPO/statusline.sh" </dev/null 2>/dev/null)
[[ -z "$line" ]] && line="break monitor: off"

echo "$line"
echo "---"
echo "Refresh now | refresh=true"
echo "Reset streak (rm stats/active.txt) | bash='/bin/rm' param1='-f' param2='$REPO/stats/active.txt' terminal=false refresh=true"
echo "Tail monitor log | bash='/usr/bin/open' param1='-a' param2='Terminal' param3='$REPO/data/monitor.log' terminal=false"
echo "Open repo | bash='/usr/bin/open' param1='$REPO' terminal=false"
