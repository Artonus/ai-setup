#!/usr/bin/env bash
# Tests that install.sh wires up the agent guard (policy, binary, OpenCode plugin, Claude hook).

test_ag_install_links_policy_binary_and_plugin() {
  run_install
  assert_eq 0 "$RC" "install exits 0"
  assert_link "$HOME/.config/agent-guard/policy.json" "$REPO/shared/agent-guard/policy.json"
  assert_link "$HOME/bin/agent-guard" "$REPO/tools/bin/agent-guard"
  assert_link "$HOME/.config/opencode/plugins/agent-guard" "$REPO/opencode/plugins/agent-guard"
}

test_ag_install_settings_register_the_pretooluse_hook() {
  local cmd='"$HOME/bin/agent-guard" claude'
  if jq -e --arg c "$cmd" '.hooks.PreToolUse | map(select(.matcher == "Bash|Write|Edit|MultiEdit|NotebookEdit")
      | .hooks[] | select(.type == "command" and .command == $c and .onFailure == "block")) | length == 1' \
      "$REPO/claude/settings.json" >/dev/null; then ok; else fail "PreToolUse guard hook missing or wrong"; fi
  if jq -e '.hooks.SessionStart | length == 1' "$REPO/claude/settings.json" >/dev/null; then ok; else fail "SessionStart hook lost"; fi
}

test_ag_install_overlay_policy_is_merged() {
  OV="$T/guard overlay"
  mkdir -p "$OV/shared/agent-guard"
  printf '{"dbClients":["clickhouse-client"]}\n' > "$OV/shared/agent-guard/policy.json"
  export AI_SETUP_OVERLAY="$OV"
  run_install
  assert_eq 0 "$RC" "install exits 0"
  assert_file "$HOME/.config/agent-guard/policy.json"
  if jq -e '.dbClients | index("clickhouse-client") != null and index("psql") != null' \
      "$HOME/.config/agent-guard/policy.json" >/dev/null; then ok; else fail "merged policy lacks base or overlay entry"; fi
  if jq -e '.mode == "shadow"' "$HOME/.config/agent-guard/policy.json" >/dev/null; then ok; else fail "mode should stay shadow"; fi
}

test_ag_install_rerun_changes_nothing() {
  run_install
  run_install
  assert_contains "$OUT" "ai-setup: 0 change(s)" "second run changes nothing"
}

test_ag_install_uninstall_removes_policy_and_plugin_links() {
  run_install
  run_install --uninstall
  assert_missing "$HOME/.config/agent-guard/policy.json"
  assert_missing "$HOME/.config/opencode/plugins/agent-guard"
  assert_missing "$HOME/bin/agent-guard"
}
