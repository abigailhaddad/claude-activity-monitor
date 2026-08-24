#!/usr/bin/env bash
# Run the unit test suite. Visual/interactive tests (notify_demo.sh)
# are NOT run here; invoke those by name.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

fail=0
for t in "$DIR"/test_*.sh; do
  # </dev/null so hook.sh's `input=$(cat)` never blocks waiting on a
  # terminal when the suite is run interactively.
  bash "$t" </dev/null || fail=1
  echo
done

exit "$fail"
