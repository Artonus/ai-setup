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

test_install_backs_up_user_file_that_replaced_our_link() {
  run_install
  rm "$HOME/.claude/settings.json"
  printf '{"model":"mine"}\n' > "$HOME/.claude/settings.json"
  run_install
  assert_link "$HOME/.claude/settings.json" "$REPO/claude/settings.json"
  assert_eq 1 "$(count_backups "$HOME/.claude/settings.json")" "user's file was backed up"
  local b
  for b in "$HOME/.claude/settings.json".bak.*; do
    assert_eq '{"model":"mine"}' "$(cat "$b")" "backup keeps the user's content"
  done
}

test_install_leaves_symlinked_dir_alone_when_repo_has_nothing_to_link() {
  mkdir -p "$HOME/.claude" "$T/my-agents"
  printf 'a\n' > "$T/my-agents/a.md"
  ln -s "$T/my-agents" "$HOME/.claude/agents"
  run_install
  assert_link "$HOME/.claude/agents" "$T/my-agents"
  assert_eq 0 "$(count_backups "$HOME/.claude/agents")" "no backup of the user's agents dir"
}

test_install_commit_command_linked_into_both_tools_and_idempotent() {
  run_install
  assert_link "$HOME/.claude/commands/commit.md" "$REPO/shared/commands/commit.md"
  assert_link "$HOME/.config/opencode/commands/commit.md" "$REPO/shared/commands/commit.md"
  run_install
  assert_contains "$OUT" "ai-setup: 0 change(s)" "second run changes nothing"
}

test_install_merges_mcp_servers_into_claude_json_keeping_the_rest() {
  printf '{"numStartups": 7, "mcpServers": {"mine": {"type": "http", "url": "https://x.test"}}}\n' > "$HOME/.claude.json"
  run_install
  assert_eq 0 "$RC" "install exits 0"
  assert_eq 7 "$(jq '.numStartups' "$HOME/.claude.json")" "unrelated state is kept"
  assert_eq "https://x.test" "$(jq -r '.mcpServers.mine.url' "$HOME/.claude.json")" "user's own server is kept"
  assert_eq "https://trilium.example.com/mcp" "$(jq -r '.mcpServers.trilium.url' "$HOME/.claude.json")" "trilium is added"
  assert_eq 'Bearer ${TRILIUM_MCP_TOKEN}' "$(jq -r '.mcpServers.trilium.headers.Authorization' "$HOME/.claude.json")" "token stays an env reference"
  assert_file "$HOME/.claude.json"
}

test_install_creates_claude_json_when_missing_and_is_idempotent() {
  run_install
  assert_eq "http" "$(jq -r '.mcpServers.trilium.type' "$HOME/.claude.json")" "trilium written to a new file"
  run_install
  assert_contains "$OUT" "ai-setup: 0 change(s)" "second run changes nothing"
  assert_eq 0 "$(count_backups "$HOME/.claude.json")" "no backup when the file did not exist or did not change"
}

test_install_dry_run_leaves_claude_json_alone() {
  printf '{"a": 1}\n' > "$HOME/.claude.json"
  run_install --dry-run
  assert_contains "$OUT" "would update MCP servers" "dry run reports the merge"
  assert_eq '{"a": 1}' "$(cat "$HOME/.claude.json")" "file untouched"
}

test_install_removes_mcp_servers_it_no_longer_declares() {
  run_install
  jq '.mcpServers.extra = {"type":"http","url":"https://extra.test"}' "$HOME/.claude.json" > "$T/c.json" && mv "$T/c.json" "$HOME/.claude.json"
  printf '{"mcpServers": {}}\n' > "$REPO/claude/mcp.json"
  run_install
  assert_eq null "$(jq '.mcpServers.trilium' "$HOME/.claude.json")" "dropped server is removed"
  assert_eq "https://extra.test" "$(jq -r '.mcpServers.extra.url' "$HOME/.claude.json")" "servers we never added are kept"
}

test_uninstall_removes_only_our_mcp_servers() {
  printf '{"mcpServers": {"mine": {"type": "http", "url": "https://x.test"}}}\n' > "$HOME/.claude.json"
  run_install
  run_install --uninstall
  assert_eq null "$(jq '.mcpServers.trilium' "$HOME/.claude.json")" "trilium removed"
  assert_eq "https://x.test" "$(jq -r '.mcpServers.mine.url' "$HOME/.claude.json")" "user's server kept"
}
