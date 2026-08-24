#!/usr/bin/env bash
# Test the post-break config rewriter. It must change only the requested
# threshold line, keep its trailing comment, and leave every other line
# (including the multi-line message blocks) byte-identical.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CONFIG="$TMP/config.yaml"
cp "$DIR/../config.yaml" "$CONFIG"
ORIG="$TMP/orig.yaml"
cp "$CONFIG" "$ORIG"

eval "$(awk '/^set_config_int\(\)/,/^}$/' "$DIR/../monitor.sh")"

echo "== config writer =="

set_config_int block_minutes 90
set_config_int nudge_minutes 45
set_config_int idle_threshold_minutes 15

assert_eq "$(sed -nE 's/^block_minutes:[[:space:]]*([0-9]+).*/\1/p' "$CONFIG")" "90" "block_minutes rewritten"
assert_eq "$(sed -nE 's/^nudge_minutes:[[:space:]]*([0-9]+).*/\1/p' "$CONFIG")" "45" "nudge_minutes rewritten"
assert_eq "$(sed -nE 's/^idle_threshold_minutes:[[:space:]]*([0-9]+).*/\1/p' "$CONFIG")" "15" "idle_threshold_minutes rewritten"

# Trailing comments survive — they document what each knob does.
line=$(grep '^block_minutes:' "$CONFIG")
assert_contains "$line" "#" "trailing comment preserved"

# Untouched keys stay untouched.
assert_eq "$(sed -nE 's/^poll_interval_seconds:[[:space:]]*([0-9]+).*/\1/p' "$CONFIG")" \
          "$(sed -nE 's/^poll_interval_seconds:[[:space:]]*([0-9]+).*/\1/p' "$ORIG")" \
          "poll_interval_seconds untouched"
assert_eq "$(wc -l < "$CONFIG" | tr -d ' ')" "$(wc -l < "$ORIG" | tr -d ' ')" "line count unchanged"

# Only the three threshold lines differ from the original.
changed=$(diff "$ORIG" "$CONFIG" | grep -c '^<' || true)
assert_eq "$changed" "3" "exactly 3 lines changed"

# The literal block scalars must still parse after the rewrite —
# a mangled block_message would break the block banner entirely.
eval "$(awk '/^yaml_get\(\)/,/^}$/' "$DIR/../monitor.sh")"
assert_contains "$(yaml_get block_message)" "Claude Code is paused" "block_message still parses"
assert_contains "$(yaml_get nudge_instructions)" "break-monitor" "nudge_instructions still parses"

report
