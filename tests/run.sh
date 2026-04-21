#!/usr/bin/env bash
# Run the unit test suite. Visual/interactive tests (notify_demo.sh)
# are NOT run here; invoke those by name.

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

fail=0
for t in "$DIR"/test_*.sh; do
  bash "$t" || fail=1
  echo
done

exit "$fail"
