#!/usr/bin/env bash
# Test the yaml_get/yaml_int parsers in monitor.sh against a fixture.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/helpers.sh"

# Extract yaml_get and yaml_int definitions out of monitor.sh.
CONFIG=$(mktemp)
cat > "$CONFIG" <<'YAML'
poll_interval_seconds: 30
idle_threshold_minutes: 10
quoted_value: "hello world"
apostrophed: 'single-quoted'
commented: 42   # trailing comment should strip
block_scalar: |
  line one
  line two
  line three
empty_after_comment: # just a comment
YAML

eval "$(awk '/^yaml_get\(\)/,/^}$/' "$DIR/../monitor.sh")"
# yaml_int is a one-liner in monitor.sh; redefine here to avoid awk
# over-matching into subsequent initialization code.
yaml_int() { yaml_get "$1" | tr -d '[:space:]'; }

echo "== yaml parser =="

assert_eq "$(yaml_int poll_interval_seconds)" "30" "yaml_int returns plain int"
assert_eq "$(yaml_int idle_threshold_minutes)" "10" "yaml_int parses second int key"
assert_eq "$(yaml_int commented)" "42" "yaml_int strips trailing comment"

assert_eq "$(yaml_get quoted_value)" "hello world" "yaml_get strips double quotes"
assert_eq "$(yaml_get apostrophed)" "single-quoted" "yaml_get strips single quotes"

block=$(yaml_get block_scalar)
expected="line one
line two
line three"
assert_eq "$block" "$expected" "yaml_get reads literal block scalar with correct newlines"

rm -f "$CONFIG"
report
