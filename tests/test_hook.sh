#!/usr/bin/env bash
# Test hook.sh behavior for each possible nudge.txt state.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"
HOOK="$DIR/../hook.sh"

# Build a fake repo layout in a tmp dir, point hook.sh at it via its
# $(dirname "$0") resolution by copying the hook in.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stats" "$TMP/data"
cp "$HOOK" "$TMP/hook.sh"

NUDGE="$TMP/stats/nudge.txt"

echo "== hook.sh =="

# 1. Empty nudge file → exit 0, no output.
: > "$NUDGE"
out=$(bash "$TMP/hook.sh" 2>&1); ec=$?
assert_exit "$ec" "0" "empty nudge: exit 0"
assert_eq "$out" "" "empty nudge: no output"

# 2. Nudge tier → exit 0, body printed to stdout.
cat > "$NUDGE" <<EOF
TIER=nudge
hey take a break for real
EOF
out=$(bash "$TMP/hook.sh" 2>/dev/null); ec=$?
assert_exit "$ec" "0" "nudge: exit 0"
assert_contains "$out" "take a break" "nudge: body printed"

# 3. Block tier → exit 2, body on stderr (refuses the prompt).
cat > "$NUDGE" <<EOF
TIER=block
you are blocked, step away
EOF
stderr=$(bash "$TMP/hook.sh" 2>&1 >/dev/null); ec=$?
assert_exit "$ec" "2" "block: exit 2 (prompt refused)"
assert_contains "$stderr" "you are blocked" "block: body on stderr"

# 4. Stale nudge (mtime > 180s) → ignored, exit 0.
cat > "$NUDGE" <<EOF
TIER=block
this is stale and should be ignored
EOF
# Backdate the file 5 minutes.
touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-5 min' +%Y%m%d%H%M.%S)" "$NUDGE"
out=$(bash "$TMP/hook.sh" 2>&1); ec=$?
assert_exit "$ec" "0" "stale nudge: exit 0 (not blocked)"
assert_eq "$out" "" "stale nudge: no output"

report
