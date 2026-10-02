test_install_links_claude_and_opencode_files() {
  run_install
  assert_eq 0 "$RC" "install exits 0"
  assert_link "$HOME/.claude/AGENTS.md" "$REPO/shared/AGENTS.md"
  assert_link "$HOME/.claude/CLAUDE.md" "$REPO/claude/CLAUDE.md"
  assert_link "$HOME/.claude/settings.json" "$REPO/claude/settings.json"
  assert_link "$HOME/.claude/skills/demo" "$REPO/shared/skills/demo"
  assert_link "$HOME/.claude/commands/hello.md" "$REPO/shared/commands/hello.md"
  assert_link "$HOME/.config/opencode/AGENTS.md" "$REPO/shared/AGENTS.md"
  assert_link "$HOME/.config/opencode/opencode.json" "$REPO/opencode/opencode.json"
  assert_missing "$HOME/.config/opencode/skills" # OpenCode reads ~/.claude/skills itself
  assert_link "$HOME/.config/opencode/commands/hello.md" "$REPO/shared/commands/hello.md"
}

test_install_is_idempotent() {
  run_install
  run_install
  assert_eq 0 "$RC" "second run exits 0"
  assert_contains "$OUT" "ai-setup: 0 change(s)" "second run changes nothing"
}

test_install_dry_run_changes_nothing() {
  run_install --dry-run
  assert_eq 0 "$RC" "dry run exits 0"
  assert_contains "$OUT" "would link" "dry run reports planned links"
  assert_contains "$OUT" "(dry run)" "dry run says so"
  assert_missing "$HOME/.claude"
  assert_missing "$HOME/.config"
  assert_missing "$HOME/.local"
}

test_install_backs_up_existing_real_file() {
  mkdir -p "$HOME/.claude"
  printf 'mine\n' > "$HOME/.claude/CLAUDE.md"
  run_install
  assert_link "$HOME/.claude/CLAUDE.md" "$REPO/claude/CLAUDE.md"
  assert_eq 1 "$(count_backups "$HOME/.claude/CLAUDE.md")" "exactly one backup"
  local b
  for b in "$HOME/.claude/CLAUDE.md".bak.*; do
    assert_eq "mine" "$(cat "$b")" "backup keeps the original content"
  done
}

test_install_does_not_write_through_symlinked_target_dir() {
  mkdir -p "$HOME/.claude" "$T/elsewhere"
  ln -s "$T/elsewhere" "$HOME/.claude/skills"
  run_install
  assert_eq 0 "$(ls -A "$T/elsewhere" | wc -l | tr -d ' ')" "symlinked dir was not written through"
  assert_link "$HOME/.claude/skills/demo" "$REPO/shared/skills/demo"
  assert_eq 1 "$(count_backups "$HOME/.claude/skills")" "old dir symlink was backed up"
}

test_install_rejects_unknown_option() {
  run_install --bogus
  if [ "$RC" != 0 ]; then ok; else fail "unknown option should fail"; fi
  assert_contains "$OUT" "unknown option" "error names the problem"
}
