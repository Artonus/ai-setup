#!/usr/bin/env bash
# Runs every test_* function from tests/test_*.sh, each in a fresh sandbox.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

command -v jq >/dev/null 2>&1 || { echo "tests need jq" >&2; exit 2; }

# shellcheck source=lib.sh
source "$here/lib.sh"
for f in "$here"/test_*.sh; do
  # shellcheck disable=SC1090
  source "$f"
done

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  printf '%s\n' "$t"
  new_env
  "$t"
  rm -rf "$T"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
