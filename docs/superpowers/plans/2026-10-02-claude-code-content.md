# Claude Code Content Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill the empty baseline with my Claude Code settings, plugins, permission rules, global rules and a `commit` command.

**Architecture:** Content only, no installer changes. `claude/settings.json` gains settings, plugins and permission rules; `shared/AGENTS.md` gains rules; `shared/commands/commit.md` is new and is linked into both tools by the existing installer. Plain-bash tests (`tests/test_*.sh`, run by `tests/run.sh`) assert the content.

**Tech Stack:** bash, jq, JSON, markdown.

**Spec:** `docs/superpowers/specs/2026-10-02-claude-code-content-design.md`

## Global Constraints

- Public repo: no tokens, keys, internal URLs or work-specific rules.
- Permission rules use the `Bash(<cmd>:*)` prefix form already used in `overlay.example/claude/settings.json`.
- `permissions.deny` stays a pure array of strings with no duplicates (overlay merge unions arrays).
- `commit.md` frontmatter contains only `description` (fields both Claude Code and OpenCode accept).
- Not allowed (must still prompt): `git push`, `gh pr create`, dependency installs.
- `shared/commands/.gitkeep`, `shared/agents/.gitkeep` and `shared/skills/.gitkeep` stay (the layout test requires them).
- The `notes` agent is out of scope; do not add it.
- Commit only what each task lists. Commit messages use conventional commits.

## Review Focus

- The existing overlay test hardcodes `deny | length == 3`; growing the base deny list breaks it unless it is made relative to the base. (Task 1)
- A rule accidentally in both `allow` and `deny`, or a duplicate in `deny`, would make the merged union misleading. (Task 1)
- An over-broad `allow` entry such as `Bash(git push:*)` or `Bash(npm install:*)` silently removes a prompt the spec says to keep. (Task 1)
- `commit.md` must install into `~/.claude/commands/` and the OpenCode commands dir, and survive an idempotent second run. (Task 2)
- `AGENTS.md` must still contain the original three rules, since the work overlay replaces the file and people copy from it. (Task 2)

---

### Task 1: settings.json content

**Files:**
- Modify: `claude/settings.json`
- Modify: `tests/test_layout.sh` (append tests)
- Modify: `tests/test_overlay.sh:25-31` (make the deny count relative)

**Interfaces:**
- Consumes: `jq`, `ROOT`, `ok`, `fail` from `tests/lib.sh`.
- Produces: `claude/settings.json` keys `model`, `tui`, `enabledPlugins`, `permissions.allow`, `permissions.deny`. Task 2 does not depend on it.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_layout.sh`:

```bash

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
```

In `tests/test_overlay.sh`, replace the line

```bash
  if jq -e '.permissions.deny | length == 3' "$HOME/.claude/settings.json" >/dev/null; then ok; else fail "deny should be a union of 3"; fi
```

with

```bash
  local base_n
  base_n="$(jq '.permissions.deny | length' "$REPO/claude/settings.json")"
  if jq -e --argjson n "$((base_n + 1))" '.permissions.deny | length == $n' "$HOME/.claude/settings.json" >/dev/null; then ok; else fail "deny should be the base rules plus the overlay's one"; fi
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh 2>&1 | grep -E "FAIL|passed"`
Expected: FAIL lines for `model/tui not set`, the plugin rules, the new deny and allow rules; the final line reports failures. The overlay deep-merge test still passes at this point (base is 2, so 2+1 = 3).

- [ ] **Step 3: Write the implementation**

Replace `claude/settings.json` with:

```json
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "model": "sonnet",
  "tui": "fullscreen",
  "enabledPlugins": {
    "superpowers@claude-plugins-official": true,
    "frontend-design@claude-plugins-official": true,
    "context7@claude-plugins-official": true
  },
  "permissions": {
    "allow": [
      "Bash(git status:*)",
      "Bash(git diff:*)",
      "Bash(git log:*)",
      "Bash(git show:*)",
      "Bash(git branch:*)",
      "Bash(ls:*)",
      "Bash(cat:*)",
      "Bash(grep:*)",
      "Bash(rg:*)",
      "Bash(gh pr view:*)",
      "Bash(gh pr list:*)",
      "Bash(gh run view:*)",
      "Bash(git add:*)",
      "Bash(git commit:*)",
      "Bash(git checkout:*)",
      "Bash(git switch:*)",
      "Bash(git stash:*)",
      "Bash(npm test:*)",
      "Bash(npm run test:*)",
      "Bash(npm run lint:*)",
      "Bash(npm run build:*)",
      "Bash(pnpm test:*)",
      "Bash(pnpm lint:*)",
      "Bash(pytest:*)",
      "Bash(ruff:*)",
      "Bash(go test:*)",
      "Bash(cargo test:*)",
      "Bash(cargo check:*)",
      "Bash(bash tests/run.sh:*)"
    ],
    "deny": [
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(~/.ssh/**)",
      "Read(~/.aws/**)",
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(git reset --hard:*)",
      "Bash(rm -rf:*)",
      "Bash(sudo:*)"
    ]
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh 2>&1 | grep -E "FAIL|passed"`
Expected: no `FAIL` lines; `N passed, 0 failed`.

- [ ] **Step 5: Commit the spec, plan and settings**

```bash
git add claude/settings.json tests/test_layout.sh tests/test_overlay.sh \
  docs/superpowers/specs/2026-10-02-claude-code-content-design.md \
  docs/superpowers/plans/2026-10-02-claude-code-content.md
git commit -m "feat(claude): add settings, plugins and permission rules"
```

---

### Task 2: AGENTS.md rules and commit command

**Files:**
- Modify: `shared/AGENTS.md`
- Create: `shared/commands/commit.md`
- Modify: `tests/test_layout.sh` (append tests)
- Modify: `tests/test_install.sh` (append one test)

**Interfaces:**
- Consumes: `new_env`, `run_install`, `assert_link`, `assert_contains`, `assert_eq`, `$REPO`, `$HOME`, `$OUT` from `tests/lib.sh`. The installer already links every `shared/commands/*` entry into `~/.claude/commands/` and `~/.config/opencode/commands/`.
- Produces: `shared/commands/commit.md`, referenced by name from the spec's override path.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_layout.sh`:

```bash

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
```

Append to `tests/test_install.sh`:

```bash

test_install_commit_command_linked_into_both_tools_and_idempotent() {
  run_install
  assert_link "$HOME/.claude/commands/commit.md" "$REPO/shared/commands/commit.md"
  assert_link "$HOME/.config/opencode/commands/commit.md" "$REPO/shared/commands/commit.md"
  run_install
  assert_contains "$OUT" "ai-setup: 0 change(s)" "second run changes nothing"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash tests/run.sh 2>&1 | grep -E "FAIL|passed"`
Expected: FAIL for the new rules, `missing shared/commands/commit.md`, and the two commit.md link assertions.

- [ ] **Step 3: Write the implementation**

Replace `shared/AGENTS.md` with:

```markdown
# Global agent instructions

These apply to every project, in both Claude Code and OpenCode.

- Ask before destructive or hard-to-reverse actions (deleting data, force-pushing, dropping tables).
- Match the style and conventions of the surrounding code.
- Never write secrets, tokens, or credentials into files or commit messages.
- Run the project's tests before claiming something works.
- Commit only when asked, and keep commits small and focused.
- Use conventional commits (`type(scope): subject`) unless the repo's recent history or its own CLAUDE.md uses a different style.
- Prefer editing existing files to creating new ones.
- Do not add dependencies without saying so.
```

Create `shared/commands/commit.md`:

```markdown
---
description: Commit the staged changes with a conventional commit message
---

Commit the currently staged changes.

1. Run `git diff --staged` to see exactly what will be committed. If nothing is staged, say so and stop. Do not stage anything yourself.
2. Run `git log --oneline -10` to check the repo's commit style.
3. Write the message in conventional commit format (`type(scope): subject`, imperative mood, subject under 72 characters), unless the recent history clearly uses another style; then follow that style. Add a short body only when the why is not obvious from the diff.
4. Commit with `git commit`. Do not push.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash tests/run.sh 2>&1 | grep -E "FAIL|passed"`
Expected: no `FAIL` lines; `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add shared/AGENTS.md shared/commands/commit.md tests/test_layout.sh tests/test_install.sh
git commit -m "feat(shared): add global rules and commit command"
```

---

### Task 3: Install on this machine and verify

**Files:**
- Modify: none (verification only; the installer moves existing files to `.bak.<timestamp>`, never deletes)

**Interfaces:**
- Consumes: the finished repo from Tasks 1 and 2.
- Produces: installed links under `~/.claude` and `~/.config/opencode`.

- [ ] **Step 1: Dry run**

Run: `./install.sh --dry-run`
Expected: plans to back up the real `~/.claude/settings.json` and link the new files; no `notes` agent changes; nothing written.

- [ ] **Step 2: Install**

Run: `./install.sh`
Expected: `ai-setup: N change(s)`; `~/.claude/settings.json.bak.<timestamp>` holds the previous settings.

- [ ] **Step 3: Verify**

Run: `ls -l ~/.claude/CLAUDE.md ~/.claude/AGENTS.md ~/.claude/settings.json ~/.claude/commands/commit.md && jq '.enabledPlugins' ~/.claude/settings.json && ./install.sh`
Expected: symlinks into the repo; all three plugins `true`; second `./install.sh` reports `0 change(s)`. `~/.claude/agents/notes.md` is untouched.

- [ ] **Step 4: Report**

Tell the user that Claude Code reads settings at session start, so a new session is needed for plugin and permission changes to apply. No commit.
