#!/usr/bin/env bash
# Runs the node:test suite for the OpenCode agent-guard plugin.

test_ag_opencode_plugin() {
  if ! command -v node >/dev/null 2>&1; then ok; return; fi
  local out rc=0
  out="$(node --test "$ROOT/tests/agent_guard_opencode.test.mjs" 2>&1)" || rc=$?
  assert_eq 0 "$rc" "node --test exit code ($out)"
}
