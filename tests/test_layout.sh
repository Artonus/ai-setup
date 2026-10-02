test_layout_required_files_exist() {
  local f
  for f in shared/AGENTS.md claude/CLAUDE.md claude/settings.json opencode/opencode.json \
           shared/skills/.gitkeep shared/agents/.gitkeep shared/commands/.gitkeep \
           overlay.example/README.md .gitignore; do
    if [ -e "$ROOT/$f" ]; then ok; else fail "missing $f"; fi
  done
}

test_layout_json_configs_are_valid() {
  local f
  for f in claude/settings.json opencode/opencode.json \
           overlay.example/claude/settings.json overlay.example/opencode/opencode.json; do
    if jq empty "$ROOT/$f" >/dev/null 2>&1; then ok; else fail "$f is not valid JSON"; fi
  done
}

test_layout_claude_md_imports_shared_agents() {
  assert_contains "$(cat "$ROOT/claude/CLAUDE.md")" "@~/.claude/AGENTS.md" "CLAUDE.md imports AGENTS.md"
}

test_layout_gitignore_covers_private_files() {
  local pat
  for pat in 'overlay/' '*.local.*' 'settings.local.json'; do
    if grep -qxF -- "$pat" "$ROOT/.gitignore"; then ok; else fail ".gitignore missing $pat"; fi
  done
}
