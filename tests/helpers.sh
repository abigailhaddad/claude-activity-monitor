# Shared test helpers. Source from individual test files.

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ✓ %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
    printf '  ✗ %s\n    got:  %q\n    want: %q\n' "$name" "$got" "$want"
  fi
}

assert_contains() {
  local got="$1" substring="$2" name="$3"
  if [[ "$got" == *"$substring"* ]]; then
    PASS=$((PASS + 1))
    printf '  ✓ %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
    printf '  ✗ %s\n    got: %q\n    want substring: %q\n' "$name" "$got" "$substring"
  fi
}

assert_exit() {
  local actual="$1" expected="$2" name="$3"
  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf '  ✓ %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
    printf '  ✗ %s\n    exit code got: %s  want: %s\n' "$name" "$actual" "$expected"
  fi
}

report() {
  echo
  printf 'passed: %d  failed: %d\n' "$PASS" "$FAIL"
  if (( FAIL > 0 )); then
    printf 'failures:\n'
    printf '  - %s\n' "${FAILED_TESTS[@]}"
    exit 1
  fi
}
