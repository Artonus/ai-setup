test_uninstall_removes_only_managed_links() {
  run_install
  printf 'keep\n' > "$HOME/.claude/mine.txt"
  run_install --uninstall
  assert_eq 0 "$RC" "uninstall exits 0"
  assert_missing "$HOME/.claude/CLAUDE.md"
  assert_missing "$HOME/.claude/skills/demo"
  assert_missing "$HOME/.config/opencode/opencode.json"
  assert_file "$HOME/.claude/mine.txt"
  assert_missing "$HOME/.local/state/ai-setup/manifest"
  assert_eq 0 "$(find "$HOME" -type l | wc -l | tr -d ' ')" "no symlinks left behind"
}

test_uninstall_dry_run_changes_nothing() {
  run_install
  run_install --uninstall --dry-run
  assert_contains "$OUT" "would remove" "dry run reports planned removals"
  assert_link "$HOME/.claude/CLAUDE.md" "$REPO/claude/CLAUDE.md"
  assert_file "$HOME/.local/state/ai-setup/manifest"
}

test_uninstall_without_manifest_is_a_noop() {
  run_install --uninstall
  assert_eq 0 "$RC" "exits 0"
  assert_contains "$OUT" "nothing to uninstall" "says so"
}

test_install_prunes_links_for_removed_entries() {
  run_install
  rm -rf "$REPO/shared/skills/demo"
  run_install
  assert_missing "$HOME/.claude/skills/demo"
  assert_missing "$HOME/.config/opencode/skills/demo"
  assert_link "$HOME/.claude/CLAUDE.md" "$REPO/claude/CLAUDE.md"
}

test_uninstall_keeps_file_the_user_put_in_place_of_ours() {
  run_install
  rm "$HOME/.claude/settings.json"
  printf '{"model":"mine"}\n' > "$HOME/.claude/settings.json"
  run_install --uninstall
  assert_file "$HOME/.claude/settings.json"
  assert_eq '{"model":"mine"}' "$(cat "$HOME/.claude/settings.json")" "user's file untouched"
  assert_missing "$HOME/.claude/CLAUDE.md"
}

test_install_prune_keeps_user_replacement_of_stale_link() {
  run_install
  rm "$HOME/.claude/skills/demo"
  mkdir "$HOME/.claude/skills/demo"
  printf 'mine\n' > "$HOME/.claude/skills/demo/SKILL.md"
  rm -rf "$REPO/shared/skills/demo"
  run_install
  assert_file "$HOME/.claude/skills/demo/SKILL.md"
}
