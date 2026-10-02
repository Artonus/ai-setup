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
  for r in 'Read(**/.env)' 'Read(**/.env.*)' 'Bash(git push --force:*)' 'Bash(git push -f:*)' \
           'Bash(git reset --hard:*)' 'Bash(rm -rf:*)' 'Bash(sudo:*)' 'Read(~/.ssh/**)' 'Read(~/.aws/**)' \
           'Bash(git diff --output:*)' 'Bash(git log --output:*)' 'Bash(git show --output:*)' \
           'Bash(git switch -f:*)' 'Bash(git switch --discard-changes:*)' \
           'Bash(rm -fr:*)' 'Bash(rm -r -f:*)' 'Bash(rm --recursive --force:*)' 'Bash(git push --force-with-lease:*)' \
           'Bash(git commit -a:*)' 'Bash(git commit --amend:*)' 'Bash(git commit --no-verify:*)'; do
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

test_layout_agents_md_keeps_original_and_new_rules() {
  local a
  a="$(cat "$ROOT/shared/AGENTS.md")"
  assert_contains "$a" "Ask before destructive" "original rule: ask before destructive actions"
  assert_contains "$a" "Match the style" "original rule: match style"
  assert_contains "$a" "Never write secrets" "original rule: no secrets"
  assert_contains "$a" "Run the project's tests before claiming" "rule: run tests"
  assert_contains "$a" "Commit only when asked" "rule: commit only when asked"
  assert_contains "$a" "conventional commits" "rule: conventional commits"
  assert_contains "$a" "unless the repo's recent history or its own CLAUDE.md" "rule: commit style defers to the repo"
  assert_contains "$a" "Prefer editing existing files" "rule: prefer editing"
  assert_contains "$a" "Do not add dependencies without saying so" "rule: dependencies"
}

test_layout_commit_command_has_only_description_frontmatter() {
  local f="$ROOT/shared/commands/commit.md" keys
  if [ -f "$f" ]; then ok; else fail "missing shared/commands/commit.md"; return; fi
  assert_eq "---" "$(sed -n 1p "$f")" "frontmatter opens on line 1"
  keys="$(awk 'NR==1{next} /^---$/{exit} {print}' "$f" | sed 's/:.*//' | sort -u | tr '\n' ' ')"
  assert_eq "description " "$keys" "frontmatter has only description"
  assert_contains "$(cat "$f")" "conventional" "commit command defaults to conventional commits"
}

test_layout_settings_allow_nothing_that_bypasses_read_denies_or_destroys_work() {
  local s="$ROOT/claude/settings.json" r
  for r in 'Bash(ruff:*)' 'Bash(cat:*)' 'Bash(grep:*)' 'Bash(rg:*)' 'Bash(git checkout:*)' 'Bash(git stash:*)' 'Bash(git branch:*)'; do
    if jq -e --arg r "$r" '.permissions.allow | index($r) == null' "$s" >/dev/null; then ok; else fail "allow must not contain $r"; fi
  done
}

test_layout_opencode_declares_context7_without_a_literal_key() {
  local o="$ROOT/opencode/opencode.json"
  if jq -e '.mcp.context7.type == "remote" and .mcp.context7.url == "https://mcp.context7.com/mcp" and .mcp.context7.enabled == true' "$o" >/dev/null; then ok; else fail "context7 MCP not declared"; fi
  if jq -e '.mcp.context7.headers.CONTEXT7_API_KEY == "{env:CONTEXT7_API_KEY}"' "$o" >/dev/null; then ok; else fail "context7 key must come from {env:CONTEXT7_API_KEY}"; fi
}

test_layout_agents_md_has_context7_guidance() {
  local a
  a="$(cat "$ROOT/shared/AGENTS.md")"
  assert_contains "$a" "Context7" "AGENTS.md mentions Context7"
  assert_contains "$a" "resolve-library-id" "AGENTS.md names the resolve step"
  assert_contains "$a" "query-docs" "AGENTS.md names the query step"
}
