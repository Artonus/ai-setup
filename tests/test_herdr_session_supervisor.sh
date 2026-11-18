#!/usr/bin/env bash

test_herdr_session_supervisor_waiter() {
  local out rc=0
  out="$(python3 "$ROOT/shared/skills/herdr-session-supervisor/tests/test_wait_for_run.py" 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then ok; else fail "Herdr waiter behavioral tests: $out"; fi
}
