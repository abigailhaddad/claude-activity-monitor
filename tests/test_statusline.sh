#!/usr/bin/env bash
# Test statusline.sh output at each tier by fabricating state.json and
# active.txt in a temp repo layout.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stats" "$TMP/data"

# Minimal config with known thresholds.
cat > "$TMP/config.yaml" <<'YAML'
idle_threshold_minutes: 10
nudge_minutes: 60
block_minutes: 120
YAML

cp "$DIR/../statusline.sh" "$TMP/statusline.sh"
chmod +x "$TMP/statusline.sh"

now=$(date +%s)
write_state() {
  local mins_ago=$1
  local ts=$(( now - mins_ago * 60 ))
  printf '{"last_event":%d,"streak_start":%d,"last_notified":0,"last_release":0}\n' \
    "$ts" "$ts" > "$TMP/data/state.json"
}
write_nudge() {
  local tier=$1
  printf 'TIER=%s\nbody\n' "$tier" > "$TMP/stats/active.txt"
  touch "$TMP/stats/active.txt"   # fresh mtime
}
clear_nudge() { : > "$TMP/stats/active.txt"; }

run_sl() { bash "$TMP/statusline.sh" </dev/null; }

echo "== statusline =="

# Monitor off (no state, no config-right-path).
rm -f "$TMP/data/state.json"
out=$(run_sl)
assert_contains "$out" "break monitor: off" "no state: monitor-off message"

# Stale state.json (>2 min old): monitor-stopped marker.
write_state 30
# Backdate state.json 5 minutes.
touch -t "$(date -v-5M +%Y%m%d%H%M.%S 2>/dev/null || date -d '5 min ago' +%Y%m%d%H%M.%S)" "$TMP/data/state.json"
out=$(run_sl)
assert_contains "$out" "stopped" "stale state.json: monitor-stopped marker"

# Helper: fresh event (user just typed) keeps statusline in coding mode.
# write_state sets last_event = streak_start, but for most tests we want
# an independent last_event close to now so idle_min = 0 (coding mode).
write_state_coding() {
  local mins_ago=$1 block_ago=${2:-0}
  local ts=$(( now - mins_ago * 60 ))
  local bs=0
  (( block_ago > 0 )) && bs=$(( now - block_ago * 60 ))
  printf '{"last_event":%d,"streak_start":%d,"last_notified":0,"last_release":0,"block_start":%d}\n' \
    "$now" "$ts" "$bs" > "$TMP/data/state.json"
}
# On-break helper: last_event is Nm ago (so idle_min = Nm), streak older.
write_state_break() {
  local streak_mins=$1 idle_mins=$2 block_ago=${3:-0}
  local s_ts=$(( now - streak_mins * 60 ))
  local e_ts=$(( now - idle_mins * 60 ))
  local bs=0
  (( block_ago > 0 )) && bs=$(( now - block_ago * 60 ))
  printf '{"last_event":%d,"streak_start":%d,"last_notified":0,"last_release":0,"block_start":%d}\n' \
    "$e_ts" "$s_ts" "$bs" > "$TMP/data/state.json"
}

# Fresh start (streak_start=0 → "break: 0m" early return).
write_state 0
clear_nudge
out=$(run_sl)
assert_contains "$out" "0m since break" "fresh streak: shows 0m"

# Coding mode, pre-block (30m streak, just typed): "Nm since break · blocked in Xm".
write_state_coding 30
clear_nudge
out=$(run_sl)
assert_contains "$out" "30m since break" "coding mode: shows streak"
assert_contains "$out" "blocked in 90m" "coding mode: countdown to block"

# Nudge tier labels are intentionally dropped from statusline — the
# nudge manifests as poem context in Claude's reply, not as a label
# here. Nudge tier in coding mode looks identical to pre-nudge.
write_state_coding 65
write_nudge nudge
out=$(run_sl)
assert_contains "$out" "65m since break" "coding+nudge: streak shown"
assert_contains "$out" "blocked in 55m" "coding+nudge: block countdown"

# Block tier + coding mode: "BLOCKED · break: Xm left" — the idle
# countdown is shown even mid-coding so the user sees how long the
# block has left without switching modes.
write_state_coding 130 3   # block fired 3m ago
write_nudge block
out=$(run_sl)
assert_contains "$out" "BLOCKED" "coding+block: BLOCKED label"
assert_contains "$out" "7m left" "coding+block: countdown runs on block_start, not last prompt"

# Break mode only activates when a tier is active. 65m streak + nudge
# tier + 3m idle → "break: 7m left" (counting down toward nudge clear).
write_state_break 65 3   # 65m streak, 3m idle
write_nudge nudge
out=$(run_sl)
assert_contains "$out" "resets in 7m" "nudge tier idle: shows streak-reset countdown"
# The nudge tier enforces nothing. Its countdown must not borrow the
# block's vocabulary — "break: 9m left" read as a mandated break when it
# only meant "9 more idle minutes until the streak zeroes out".
[[ "$out" == *"BLOCKED"* || "$out" == *"break:"* ]] && {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("nudge tier idle: uses enforced-break wording")
  echo "  ✗ nudge tier idle: uses enforced-break wording ($out)"
} || {
  PASS=$((PASS + 1))
  echo "  ✓ nudge tier idle: no enforced-break wording"
}

# Pre-nudge idle stays in coding mode (no tier → no break countdown).
# A freshly-reset streak must not flip into "break: 9m left" the moment
# the user pauses to read Claude's output.
write_state_break 30 3
clear_nudge
out=$(run_sl)
assert_contains "$out" "since break" "pre-nudge idle: stays in coding mode"
[[ "$out" == *"break:"*"left"* ]] && {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("pre-nudge idle: should NOT show break countdown")
  echo "  ✗ pre-nudge idle: should NOT show break countdown"
  echo "    got: $out"
} || {
  PASS=$((PASS + 1))
  echo "  ✓ pre-nudge idle: break countdown suppressed"
}

# Break mode + block tier: "BLOCKED · break: Xm left".
# REGRESSION: the monitor holds a block for a full idle_threshold from
# block_start, so the countdown must too. Here the user's last prompt was
# 9m ago but the block only fired 2m ago — measuring from the prompt would
# claim "1m left" when the block actually has 8 minutes to run.
write_state_break 130 9 2   # 130m streak, 9m idle, block fired 2m ago
write_nudge block
out=$(run_sl)
assert_contains "$out" "BLOCKED" "break+block: BLOCKED label"
assert_contains "$out" "8m left" "break+block: countdown from block_start not last prompt"
[[ "$out" == *"1m left"* ]] && {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("break+block: countdown measured from last prompt")
  echo "  ✗ break+block: countdown measured from last prompt (block would lift early)"
} || {
  PASS=$((PASS + 1))
  echo "  ✓ break+block: does not measure the break from the last prompt"
}

# Idle past threshold but monitor hasn't reset yet (transient):
# should show "done, resetting" not "0m left". Needs an active tier
# since break mode is tier-gated now.
write_state_break 65 15  # 65m streak, 15m idle (capped to 10m)
write_nudge nudge
out=$(run_sl)
assert_contains "$out" "streak resetting" "idle past threshold: done-marker not 0m"

# Reset feedback: typing (last_event = now) flips back to coding mode.
write_state_coding 30
clear_nudge
out=$(run_sl)
assert_contains "$out" "since break" "type during break: back to coding mode"
[[ "$out" == *"break:"*"left"* ]] && {
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("type during break: should NOT show break countdown")
  echo "  ✗ type during break: should NOT show break countdown"
  echo "    got: $out"
} || {
  PASS=$((PASS + 1))
  echo "  ✓ type during break: break countdown hidden"
}

# Fallback: nudge empty but streak math >= block threshold.
write_state 130
clear_nudge
out=$(run_sl)
assert_contains "$out" "BLOCKED" "no nudge + streak past block: fallback to BLOCKED"

# Release banner: last_release > last_prompt, shown before next prompt.
release_ts=$now
printf '{"last_event":%d,"streak_start":%d,"last_notified":0,"last_release":%d}\n' \
  "$now" "$now" "$release_ts" > "$TMP/data/state.json"
clear_nudge
rm -f "$TMP/data/last_prompt.ts"
out=$(run_sl)
assert_contains "$out" "break registered" "release > last_prompt: banner shown"

# Release banner clears once a prompt arrives (last_prompt newer).
touch "$TMP/data/last_prompt.ts"
sleep 1
release_ts=$(( now - 5 ))
printf '{"last_event":%d,"streak_start":%d,"last_notified":0,"last_release":%d}\n' \
  "$now" "$now" "$release_ts" > "$TMP/data/state.json"
out=$(run_sl)
if [[ "$out" == *"break registered"* ]]; then
  FAIL=$((FAIL + 1))
  FAILED_TESTS+=("release < last_prompt: banner should be cleared")
  echo "  ✗ release < last_prompt: banner should be cleared"
  echo "    got: $out"
else
  PASS=$((PASS + 1))
  echo "  ✓ release < last_prompt: banner cleared after prompt"
fi

report
