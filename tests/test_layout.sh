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

test_layout_settings_declare_defaults_and_plugins() {
  local s="$ROOT/claude/settings.json" p
  if jq -e '.model == "sonnet" and .tui == "fullscreen"' "$s" >/dev/null; then ok; else fail "model/tui not set"; fi
  for p in superpowers frontend-design context7; do
    if jq -e --arg p "$p@claude-plugins-official" '.enabledPlugins[$p] == true' "$s" >/dev/null; then ok; else fail "plugin $p not enabled"; fi
  done
}

test_layout_settings_deny_dangerous_commands() {
  local s="$ROOT/claude/settings.json" r
  for r in 'Read(./.env)' 'Read(./.env.*)' 'Bash(git push --force:*)' 'Bash(git push -f:*)' \
           'Bash(git reset --hard:*)' 'Bash(rm -rf:*)' 'Bash(sudo:*)' 'Read(~/.ssh/**)' 'Read(~/.aws/**)'; do
    if jq -e --arg r "$r" '.permissions.deny | index($r) != null' "$s" >/dev/null; then ok; else fail "deny missing $r"; fi
  done
  if jq -e '.permissions.deny | (unique | length) == length' "$s" >/dev/null; then ok; else fail "deny has duplicates"; fi
}

test_layout_settings_allow_routine_commands() {
  local s="$ROOT/claude/settings.json" r
  for r in 'Bash(git status:*)' 'Bash(git diff:*)' 'Bash(git log:*)' 'Bash(git add:*)' 'Bash(git commit:*)' \
           'Bash(gh pr view:*)' 'Bash(npm test:*)' 'Bash(pytest:*)' 'Bash(bash tests/run.sh:*)'; do
    if jq -e --arg r "$r" '.permissions.allow | index($r) != null' "$s" >/dev/null; then ok; else fail "allow missing $r"; fi
  done
}

test_layout_settings_keep_outward_actions_prompting() {
  local s="$ROOT/claude/settings.json"
  if jq -e '[.permissions.allow[] | select(test("^Bash\\((git push|gh pr create|npm install|pnpm install|pip install)"))] | length == 0' "$s" >/dev/null; then ok; else fail "an outward-facing command is allowed"; fi
  if jq -e '(.permissions.allow - .permissions.deny) == .permissions.allow' "$s" >/dev/null; then ok; else fail "a rule is in both allow and deny"; fi
}
