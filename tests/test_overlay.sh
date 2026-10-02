new_overlay() { # creates $OV and exports AI_SETUP_OVERLAY
  OV="$T/work overlay"
  mkdir -p "$OV/shared" "$OV/claude" "$OV/opencode"
  export AI_SETUP_OVERLAY="$OV"
}

test_overlay_file_replaces_base_file() {
  new_overlay
  printf 'work rules\n' > "$OV/shared/AGENTS.md"
  run_install
  assert_link "$HOME/.claude/AGENTS.md" "$OV/shared/AGENTS.md"
  assert_link "$HOME/.config/opencode/AGENTS.md" "$OV/shared/AGENTS.md"
  assert_link "$HOME/.claude/CLAUDE.md" "$REPO/claude/CLAUDE.md"
}

test_overlay_adds_entries_next_to_base_entries() {
  new_overlay
  mkdir -p "$OV/shared/skills/work-only"
  printf '# work\n' > "$OV/shared/skills/work-only/SKILL.md"
  run_install
  assert_link "$HOME/.claude/skills/work-only" "$OV/shared/skills/work-only"
  assert_missing "$HOME/.config/opencode/skills" # OpenCode reads ~/.claude/skills itself
  assert_link "$HOME/.claude/skills/demo" "$REPO/shared/skills/demo"
}

test_overlay_entry_overrides_same_named_base_entry() {
  new_overlay
  mkdir -p "$OV/shared/skills/demo"
  printf '# work demo\n' > "$OV/shared/skills/demo/SKILL.md"
  run_install
  assert_link "$HOME/.claude/skills/demo" "$OV/shared/skills/demo"
}

test_overlay_claude_settings_are_deep_merged() {
  new_overlay
  printf '{"env":{"WORK_MODE":"1"},"permissions":{"deny":["Bash(curl:*)"]}}\n' > "$OV/claude/settings.json"
  run_install
  assert_file "$HOME/.claude/settings.json"
  if jq -e '.env.WORK_MODE == "1"' "$HOME/.claude/settings.json" >/dev/null; then ok; else fail "overlay env missing"; fi
  if jq -e '.permissions.deny | index("Read(./.env)") != null' "$HOME/.claude/settings.json" >/dev/null; then ok; else fail "base deny was lost"; fi
  if jq -e '.permissions.deny | index("Bash(curl:*)") != null' "$HOME/.claude/settings.json" >/dev/null; then ok; else fail "overlay deny missing"; fi
  local base_n
  base_n="$(jq '.permissions.deny | length' "$REPO/claude/settings.json")"
  if jq -e --argjson n "$((base_n + 1))" '.permissions.deny | length == $n' "$HOME/.claude/settings.json" >/dev/null; then ok; else fail "deny should be the base rules plus the overlay's one"; fi
}

test_overlay_opencode_json_is_merged() {
  new_overlay
  printf '{"mcp":{"work":{"type":"remote","url":"https://mcp.example.com"}}}\n' > "$OV/opencode/opencode.json"
  run_install
  assert_file "$HOME/.config/opencode/opencode.json"
  if jq -e '.mcp.work.type == "remote" and (.["$schema"] != null)' "$HOME/.config/opencode/opencode.json" >/dev/null; then ok; else fail "opencode merge wrong"; fi
}

test_overlay_merged_json_rerun_is_idempotent() {
  new_overlay
  printf '{"env":{"WORK_MODE":"1"}}\n' > "$OV/claude/settings.json"
  run_install
  run_install
  assert_contains "$OUT" "ai-setup: 0 change(s)" "second run changes nothing"
  assert_eq 0 "$(count_backups "$HOME/.claude/settings.json")" "no backup clutter"
}

test_overlay_dropped_returns_merged_json_to_symlink() {
  new_overlay
  printf '{"env":{"WORK_MODE":"1"}}\n' > "$OV/claude/settings.json"
  run_install
  unset AI_SETUP_OVERLAY
  run_install
  assert_link "$HOME/.claude/settings.json" "$REPO/claude/settings.json"
  assert_eq 0 "$(count_backups "$HOME/.claude/settings.json")" "no backup clutter"
}

test_overlay_missing_dir_is_an_error() {
  export AI_SETUP_OVERLAY="$T/nope"
  run_install
  if [ "$RC" != 0 ]; then ok; else fail "should fail when overlay dir is missing"; fi
  assert_contains "$OUT" "AI_SETUP_OVERLAY" "error names the variable"
  assert_missing "$HOME/.claude"
}

test_overlay_invalid_json_is_rejected_before_any_change() {
  new_overlay
  printf '{ not json\n' > "$OV/claude/settings.json"
  run_install
  if [ "$RC" != 0 ]; then ok; else fail "should fail on invalid overlay JSON"; fi
  assert_contains "$OUT" "invalid JSON" "error says what is wrong"
  assert_missing "$HOME/.claude"
}

test_overlay_merged_json_dry_run_writes_nothing() {
  new_overlay
  printf '{"env":{"WORK_MODE":"1"}}\n' > "$OV/claude/settings.json"
  run_install --dry-run
  assert_contains "$OUT" "would write" "dry run reports the merged file"
  assert_missing "$HOME/.claude/settings.json"
}

test_overlay_edited_generated_file_is_backed_up_not_lost() {
  new_overlay
  printf '{"env":{"WORK_MODE":"1"}}\n' > "$OV/claude/settings.json"
  run_install
  printf '{"edited":true}\n' > "$HOME/.claude/settings.json"
  run_install
  assert_eq 1 "$(count_backups "$HOME/.claude/settings.json")" "the edit survives as a backup"
  local b
  for b in "$HOME/.claude/settings.json".bak.*; do
    assert_eq '{"edited":true}' "$(cat "$b")" "backup keeps the edit"
  done
  if jq -e '.env.WORK_MODE == "1"' "$HOME/.claude/settings.json" >/dev/null; then ok; else fail "merged file was not regenerated"; fi
}

test_overlay_relative_path_is_made_absolute() {
  new_overlay
  printf 'work\n' > "$OV/shared/AGENTS.md"
  RC=0
  OUT="$(cd "$T" && AI_SETUP_OVERLAY="work overlay" bash "$REPO/install.sh" 2>&1)" || RC=$?
  assert_eq 0 "$RC" "relative overlay path works"
  assert_link "$HOME/.claude/AGENTS.md" "$OV/shared/AGENTS.md"
}

test_overlay_empty_json_file_is_rejected() {
  new_overlay
  : > "$OV/claude/settings.json"
  run_install
  if [ "$RC" != 0 ]; then ok; else fail "empty overlay JSON should fail"; fi
  assert_missing "$HOME/.claude"
}

test_overlay_non_object_json_is_rejected() {
  new_overlay
  printf '[]\n' > "$OV/claude/settings.json"
  run_install
  if [ "$RC" != 0 ]; then ok; else fail "array overlay JSON should fail"; fi
  assert_contains "$OUT" "expected an object" "error says what is wrong"
  assert_missing "$HOME/.claude"
}

test_overlay_type_mismatch_is_rejected_before_any_change() {
  new_overlay
  printf '{"permissions":{"deny":"x"}}\n' > "$OV/claude/settings.json"
  run_install
  if [ "$RC" != 0 ]; then ok; else fail "type mismatch should fail"; fi
  assert_contains "$OUT" "cannot merge" "error says what is wrong"
  assert_missing "$HOME/.claude"
}
