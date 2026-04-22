#!/usr/bin/env bash
# Test hook.sh behavior for each possible active.txt state.

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

ACTIVE="$TMP/stats/active.txt"
LAST_PROMPT="$TMP/data/last_prompt.ts"

echo "== hook.sh =="

# 1. Empty active file → exit 0, no output.
: > "$ACTIVE"
out=$(bash "$TMP/hook.sh" 2>&1); ec=$?
assert_exit "$ec" "0" "empty active: exit 0"
assert_eq "$out" "" "empty active: no output"

# 2. Nudge tier → exit 0, body printed to stdout.
cat > "$ACTIVE" <<EOF
TIER=nudge
hey take a break for real
EOF
out=$(bash "$TMP/hook.sh" 2>/dev/null); ec=$?
assert_exit "$ec" "0" "nudge: exit 0"
assert_contains "$out" "take a break" "nudge: body printed"

# 3. Block tier → exit 2, body on stderr (refuses the prompt).
cat > "$ACTIVE" <<EOF
TIER=block
you are blocked, step away
EOF
stderr=$(bash "$TMP/hook.sh" 2>&1 >/dev/null); ec=$?
assert_exit "$ec" "2" "block: exit 2 (prompt refused)"
assert_contains "$stderr" "you are blocked" "block: body on stderr"

# 4. Stale active file (mtime > 180s) → ignored, exit 0.
cat > "$ACTIVE" <<EOF
TIER=block
this is stale and should be ignored
EOF
# Backdate the file 5 minutes.
touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '-5 min' +%Y%m%d%H%M.%S)" "$ACTIVE"
out=$(bash "$TMP/hook.sh" 2>&1); ec=$?
assert_exit "$ec" "0" "stale active: exit 0 (not blocked)"
assert_eq "$out" "" "stale active: no output"

# 5. Stop event → exit 0, no output, and last_prompt.ts NOT touched.
#    Response-end is deliberately not counted as engagement: the user
#    may have walked away while Claude was streaming. Only actual
#    UserPromptSubmit events (the user typing) count as activity.
cat > "$ACTIVE" <<EOF
TIER=block
you are blocked, step away
EOF
rm -f "$LAST_PROMPT"
out=$(printf '{"hook_event_name":"Stop"}' | bash "$TMP/hook.sh" 2>&1); ec=$?
assert_exit "$ec" "0" "Stop + block: exit 0 (no refusal)"
assert_eq "$out" "" "Stop: no output"
[[ ! -f "$LAST_PROMPT" ]] && {
  PASS=$((PASS + 1))
  echo "  ✓ Stop: last_prompt.ts NOT touched (response-end is not engagement)"
} || {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("Stop: last_prompt.ts was touched")
  echo "  ✗ Stop: last_prompt.ts was touched (should be user-prompts-only)"
}

# 6. UserPromptSubmit event with block tier → exit 2 (unchanged
#    behavior; confirms explicit event name works the same as the
#    no-stdin default).
rm -f "$LAST_PROMPT"
stderr=$(printf '{"hook_event_name":"UserPromptSubmit"}' | bash "$TMP/hook.sh" 2>&1 >/dev/null); ec=$?
assert_exit "$ec" "2" "UserPromptSubmit + block: exit 2 (prompt refused)"
assert_contains "$stderr" "you are blocked" "UserPromptSubmit: body on stderr"

# 7. Block tier does NOT touch last_prompt.ts. If it did, every
#    rejected attempt would reset the monitor's idle countdown and
#    the user could never unblock.
cat > "$ACTIVE" <<EOF
TIER=block
you are blocked
EOF
rm -f "$LAST_PROMPT"
bash "$TMP/hook.sh" </dev/null >/dev/null 2>&1
[[ ! -f "$LAST_PROMPT" ]] && {
  PASS=$((PASS + 1))
  echo "  ✓ block: last_prompt.ts NOT touched (idle clock protected)"
} || {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("block: last_prompt.ts was touched")
  echo "  ✗ block: last_prompt.ts was touched — user can never unblock"
}

# 8. Nudge once-per-epoch: a second prompt with unchanged active.txt
#    stays silent. First call injects (tests case 2 already proved
#    this); the marker file prevents re-injection until the monitor
#    rewrites active.txt on a tier transition.
cat > "$ACTIVE" <<EOF
TIER=nudge
hey take a break for real
EOF
rm -f "$TMP/data/last_injected.ts"
out=$(bash "$TMP/hook.sh" 2>/dev/null); ec=$?
assert_exit "$ec" "0" "nudge first call: exit 0"
assert_contains "$out" "take a break" "nudge first call: body printed"
# Second call — active.txt mtime unchanged, marker is now newer → silent.
out=$(bash "$TMP/hook.sh" 2>/dev/null); ec=$?
assert_exit "$ec" "0" "nudge second call: exit 0"
assert_eq "$out" "" "nudge second call: silent (once-per-epoch gate held)"

# 9. Nudge re-arms when active.txt is rewritten (new tier-epoch).
#    Bump active.txt's mtime forward past the marker and confirm
#    injection fires again.
sleep 1
cat > "$ACTIVE" <<EOF
TIER=nudge
hey take a different break
EOF
out=$(bash "$TMP/hook.sh" 2>/dev/null); ec=$?
assert_exit "$ec" "0" "nudge re-arm: exit 0"
assert_contains "$out" "different break" "nudge re-arm: new body injected"

report
