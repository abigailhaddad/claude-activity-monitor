#!/usr/bin/env bash
# Test placeholder substitution in render_template.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"

IDLE_THRESHOLD=600    # 10 min
NUDGE_THRESHOLD=3600  # 60 min
eval "$(awk '/^render_template\(\)/,/^}$/' "$DIR/../monitor.sh")"

echo "== render_template =="

out=$(render_template "You've been coding {mins} min, take a {idle_min}-min break" "75")
assert_eq "$out" "You've been coding 75 min, take a 10-min break" "substitutes {mins} and {idle_min}"

out=$(render_template "Nudge tier is at {nudge_min} minutes" "120")
assert_eq "$out" "Nudge tier is at 60 minutes" "substitutes {nudge_min}"

out=$(render_template "No placeholders here" "99")
assert_eq "$out" "No placeholders here" "leaves plain text alone"

out=$(render_template "multi {mins} {mins} {mins}" "5")
assert_eq "$out" "multi 5 5 5" "substitutes all occurrences of same placeholder"

report
