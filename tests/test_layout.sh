test_layout_required_files_exist() {
  local f
  for f in shared/AGENTS.md claude/CLAUDE.md claude/settings.json claude/mcp.json opencode/opencode.json \
           shared/skills/.gitkeep shared/agents/.gitkeep shared/commands/.gitkeep \
           overlay.example/README.md .gitignore; do
    if [ -e "$ROOT/$f" ]; then ok; else fail "missing $f"; fi
  done
}

test_layout_json_configs_are_valid() {
  local f
  for f in claude/settings.json claude/mcp.json opencode/opencode.json \
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
  if jq -e '.model == "opus" and .tui == "fullscreen"' "$s" >/dev/null; then ok; else fail "model/tui not set"; fi
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
  if jq -e '.mcp.servers.context7.type == "remote" and .mcp.servers.context7.url == "https://mcp.context7.com/mcp" and .mcp.servers.context7.disabled == false' "$o" >/dev/null; then ok; else fail "context7 MCP not declared"; fi
  if jq -e '.mcp.servers.context7.headers.CONTEXT7_API_KEY == "{env:CONTEXT7_API_KEY}"' "$o" >/dev/null; then ok; else fail "context7 key must come from {env:CONTEXT7_API_KEY}"; fi
}

test_layout_agents_md_has_context7_guidance() {
  local a
  a="$(cat "$ROOT/shared/AGENTS.md")"
  assert_contains "$a" "Context7" "AGENTS.md mentions Context7"
  assert_contains "$a" "resolve-library-id" "AGENTS.md names the resolve step"
  assert_contains "$a" "query-docs" "AGENTS.md names the query step"
}

test_layout_opencode_declares_todoist_with_automatic_oauth() {
  local o="$ROOT/opencode/opencode.json"
  if jq -e '.mcp.servers.todoist.type == "remote" and .mcp.servers.todoist.url == "https://ai.todoist.net/mcp" and .mcp.servers.todoist.disabled == false' "$o" >/dev/null; then ok; else fail "todoist MCP not declared"; fi
  if jq -e '.mcp.servers.todoist | has("headers") | not' "$o" >/dev/null; then ok; else fail "todoist should use OAuth, not headers"; fi
}

test_layout_opencode_google_calendar_is_off_until_credentials_exist() {
  local o="$ROOT/opencode/opencode.json"
  if jq -e '.mcp.servers["google-calendar"].type == "remote" and .mcp.servers["google-calendar"].url == "https://calendarmcp.googleapis.com/mcp/v1"' "$o" >/dev/null; then ok; else fail "google-calendar MCP not declared"; fi
  if jq -e '.mcp.servers["google-calendar"].disabled == true' "$o" >/dev/null; then ok; else fail "google-calendar must default to disabled"; fi
  if jq -e '.mcp.servers["google-calendar"].oauth.client_id == "{env:GOOGLE_MCP_CLIENT_ID}" and .mcp.servers["google-calendar"].oauth.client_secret == "{env:GOOGLE_MCP_CLIENT_SECRET}"' "$o" >/dev/null; then ok; else fail "google-calendar OAuth credentials must be {env:} references"; fi
  if jq -e '.mcp.servers["google-calendar"].oauth.scope | test("calendar.events.readonly")' "$o" >/dev/null; then ok; else fail "google-calendar scopes missing"; fi
}

test_layout_opencode_mcp_credentials_are_env_references() {
  local o="$ROOT/opencode/opencode.json"
  if jq -e '[.mcp.servers[] | ((.headers // {}) | to_entries[].value), ((.oauth // {}) | objects | (.client_id, .client_secret) | select(. != null))] | all(test("^(Bearer )?\\{env:[A-Z0-9_]+\\}$"))' "$o" >/dev/null; then ok; else fail "an MCP header or OAuth credential is not an {env:VAR} reference"; fi
}

test_layout_secrets_md_documents_every_env_reference() {
  local f="$ROOT/SECRETS.md" v vars
  if [ -f "$f" ]; then ok; else fail "missing SECRETS.md"; return; fi
  vars="$(grep -o '{env:[A-Za-z0-9_]*}' "$ROOT/opencode/opencode.json" | sed 's/{env:\(.*\)}/\1/' | sort -u)"
  for v in $vars; do
    if grep -q "\`$v\`" "$f"; then ok; else fail "SECRETS.md does not document $v"; fi
  done
}

test_layout_secrets_md_contains_no_values() {
  if grep -Eq '(sk-[A-Za-z0-9]{10,}|ctx7sk-|Bearer [A-Za-z0-9._-]{20,})' "$ROOT/SECRETS.md" 2>/dev/null; then fail "SECRETS.md looks like it contains a real key"; else ok; fi
}

test_layout_opencode_installs_superpowers_plugin() {
  local o="$ROOT/opencode/opencode.json"
  if jq -e '.plugins | index("superpowers@git+https://github.com/obra/superpowers.git") != null' "$o" >/dev/null; then ok; else fail "superpowers plugin not declared under .plugins"; fi
}

test_layout_opencode_configs_use_v2_keys_only() {
  local o
  for o in "$ROOT/opencode/opencode.json" "$ROOT/overlay.example/opencode/opencode.json"; do
    if jq -e '(has("permission") or has("plugin") or has("provider") or has("tools") or has("agent") or has("command")) | not' "$o" >/dev/null; then ok; else fail "$o has a V1 top-level key"; fi
    if jq -e '(.mcp // {}) | keys - ["servers"] | length == 0' "$o" >/dev/null; then ok; else fail "$o declares an MCP server outside .mcp.servers"; fi
    if jq -e '[(.mcp.servers // {})[] | has("enabled")] | any | not' "$o" >/dev/null; then ok; else fail "$o uses V1 .enabled instead of .disabled"; fi
  done
}

test_layout_opencode_skill_denies_are_v2_permission_rules() {
  local o="$ROOT/opencode/opencode.json"
  if jq -e '.permissions | type == "array" and all(.action and .resource and (.effect | IN("allow", "ask", "deny")))' "$o" >/dev/null; then ok; else fail "permissions must be an array of {action, resource, effect}"; fi
  if jq -e '[.permissions[] | select(.action == "skill" and .resource == "tdd" and .effect == "deny")] | length == 1' "$o" >/dev/null; then ok; else fail "skill deny rules missing"; fi
}

test_layout_opencode_declares_trilium_with_env_bearer_token() {
  local o="$ROOT/opencode/opencode.json"
  if jq -e '.mcp.servers.trilium.type == "remote" and .mcp.servers.trilium.url == "{env:TRILIUM_MCP_URL}" and .mcp.servers.trilium.disabled == false' "$o" >/dev/null; then ok; else fail "trilium MCP not declared"; fi
  if jq -e '.mcp.servers.trilium.headers.Authorization == "Bearer {env:TRILIUM_MCP_TOKEN}"' "$o" >/dev/null; then ok; else fail "trilium must use an env bearer token"; fi
}

test_layout_claude_mcp_json_declares_trilium_with_env_bearer_token() {
  local m="$ROOT/claude/mcp.json"
  if jq -e '.mcpServers.trilium.type == "http" and .mcpServers.trilium.url == "${TRILIUM_MCP_URL}"' "$m" >/dev/null; then ok; else fail "trilium not declared in claude/mcp.json"; fi
  if jq -e '[.mcpServers[].headers // {} | to_entries[].value] | all(test("^Bearer \\$\\{[A-Z0-9_]+\\}$"))' "$m" >/dev/null; then ok; else fail "claude MCP header is not a \${VAR} reference"; fi
}

test_layout_anthropic_skills_is_a_submodule() {
  if grep -q 'vendor/anthropic-skills' "$ROOT/.gitmodules" 2>/dev/null; then ok; else fail "anthropic skills submodule not declared"; fi
}

test_layout_cloudflare_security_audit_skill_is_a_submodule() {
  if grep -q 'vendor/cloudflare-security-audit-skill' "$ROOT/.gitmodules" 2>/dev/null; then ok; else fail "cloudflare security-audit skill submodule not declared"; fi
}

test_layout_matt_pocock_skills_is_a_submodule() {
  if grep -q 'vendor/mattpocock-skills' "$ROOT/.gitmodules" 2>/dev/null; then ok; else fail "mattpocock skills submodule not declared"; fi
}

test_layout_kilo_config_is_v1_with_superpowers_and_env_credentials() {
  local k="$ROOT/kilo/kilo.json"
  if jq empty "$k" >/dev/null 2>&1; then ok; else fail "kilo/kilo.json is not valid JSON"; return; fi
  if jq -e '.plugin | index("superpowers@git+https://github.com/obra/superpowers.git") != null' "$k" >/dev/null; then ok; else fail "superpowers plugin not declared under .plugin (Kilo uses V1 keys)"; fi
  if jq -e '(has("plugins") or has("permissions") or has("providers")) | not' "$k" >/dev/null; then ok; else fail "kilo/kilo.json has a V2 top-level key"; fi
  if jq -e '[.mcp[] | ((.headers // {}) | to_entries[].value), ((.environment // {}) | to_entries[].value | select(test("KEY|TOKEN|PAT|SECRET"; "i")))] | all(test("^(Bearer )?\\{env:[A-Z0-9_]+\\}$"))' "$k" >/dev/null; then ok; else fail "a Kilo MCP credential is not an {env:VAR} reference"; fi
}

test_layout_matt_workflow_skills_are_not_switched_off() {
  local s="$ROOT/claude/settings.json" o="$ROOT/opencode/opencode.json" k="$ROOT/kilo/kilo.json" n
  for n in grill-with-docs grill-me handoff improve-codebase-architecture setup-matt-pocock-skills triage; do
    if jq -e --arg n "$n" '(.skillOverrides // {})[$n] != "off"' "$s" >/dev/null; then ok; else fail "claude settings switch off $n"; fi
    if jq -e --arg n "$n" '[.permissions[] | select(.action == "skill" and .resource == $n and .effect == "deny")] | length == 0' "$o" >/dev/null; then ok; else fail "opencode denies $n"; fi
    if jq -e --arg n "$n" '(.permission.skill // {})[$n] != "deny"' "$k" >/dev/null; then ok; else fail "kilo denies $n"; fi
  done
}

test_layout_memory_search_mcp_is_wired_everywhere() {
  if [ -x "$ROOT/tools/bin/memory-search-mcp" ]; then ok; else fail "tools/bin/memory-search-mcp missing or not executable"; fi
  if jq -e '.mcpServers["memory-search"].command == "memory-search-mcp"' "$ROOT/claude/mcp.json" >/dev/null; then ok; else fail "claude/mcp.json lacks memory-search"; fi
  if jq -e '.mcp.servers["memory-search"] | .command == ["memory-search-mcp"] and .disabled == false' "$ROOT/opencode/opencode.json" >/dev/null; then ok; else fail "opencode.json lacks memory-search"; fi
  if jq -e '.mcp["memory-search"] | .command == ["memory-search-mcp"] and .enabled == true' "$ROOT/kilo/kilo.json" >/dev/null; then ok; else fail "kilo.json lacks memory-search"; fi
}
