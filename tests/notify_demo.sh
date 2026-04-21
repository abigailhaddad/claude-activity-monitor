#!/usr/bin/env bash
# Visual test: fires one notification per tier, 2 seconds apart, so you
# can confirm with your eyeballs that the banners are actually showing.
#
# Reads send_notification() out of monitor.sh to exercise the real code
# path (osascript → terminal-notifier → notify-send fallback chain).
#
# Usage:  bash tests/notify_demo.sh
# Expected: 4 banners appear in the top-right of your screen, two with
# a jarring sound (Basso) and -ignoreDnD for hard_block + release.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Pull just the send_notification function from monitor.sh.
eval "$(awk '/^send_notification\(\)/,/^}$/' "$ROOT/monitor.sh")"

echo "Firing 4 notifications, 2s apart. Watch your screen corner."
echo

echo "[1/4] gentle tier (Glass sound, no DND pierce)"
send_notification "TEST — gentle" "Stand up, look away, drink water." normal
sleep 2

echo "[2/4] firm tier (Glass sound, no DND pierce)"
send_notification "TEST — firm" "You're overdue for a break." normal
sleep 2

echo "[3/4] hard_block tier (Basso sound, -ignoreDnD)"
send_notification "TEST — PAUSED" "Claude Code paused. Step away for N min." urgent
sleep 2

echo "[4/4] release (Basso sound, -ignoreDnD)"
send_notification "TEST — break registered" "You're unblocked. Welcome back." urgent

echo
echo "Did all 4 banners appear? If not:"
echo "  - open System Settings -> Notifications"
echo "  - find 'Script Editor' (or 'terminal-notifier' if that's the backend)"
echo "  - ensure 'Allow Notifications' is ON and Alert style is Banners/Alerts (not None)"
echo "  - check the top-right corner of System Settings for a Focus/DND indicator"
