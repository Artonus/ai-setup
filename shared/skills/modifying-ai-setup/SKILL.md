---
name: modifying-ai-setup
description: Use when adding, editing, renaming or removing a global skill, agent, command, AGENTS.md rule, CLAUDE.md note, settings.json or opencode.json entry, MCP server or plugin for Claude Code or OpenCode, or when a file under ~/.claude or ~/.config/opencode needs to change.
---

# Modifying the AI setup

## Overview

`~/.claude` and `~/.config/opencode` are install targets, not sources. Their files are symlinks into the `ai-setup` repo (or generated from it). Every change is made in the repo, then installed with `install.sh`.

**Never edit, create, move or delete a skill, agent, command, `AGENTS.md`, `CLAUDE.md` or config file at its installed location.** Violating the letter of this is violating the spirit: editing "through the symlink" is still a direct edit and bypasses review, git history and the work overlay.

## Steps

1. **Find the repo:** `dirname "$(dirname "$(readlink ~/.claude/AGENTS.md)")"`. If `AGENTS.md` is not a symlink, run the installer from the repo first.
2. **Pick the source path** (work-specific or private content goes in the overlay at `$AI_SETUP_OVERLAY`, same layout, never in the public repo):

   | Change | Edit in repo |
   |---|---|
   | Global rule | `shared/AGENTS.md` |
   | Claude-only note | `claude/CLAUDE.md` |
   | Skill | `shared/skills/<name>/SKILL.md` |
   | Agent / command | `shared/agents/<name>.md`, `shared/commands/<name>.md` |
   | Claude settings, MCP | `claude/settings.json`, `claude/mcp.json` |
   | OpenCode config | `opencode/opencode.json` |
   | Third-party skills | `vendor/anthropic-skills` (submodule; do not edit, add your own in `shared/skills/`) |

3. Make the change there, matching the surrounding style. Add a test in `tests/` if the installer or layout is affected.
4. Run `bash tests/run.sh`, then `./install.sh --dry-run`, then `./install.sh`.
5. Commit in the repo only when asked (conventional commits).

## Red flags - stop

- A path starting with `~/.claude/` or `~/.config/opencode/` in an Edit/Write/`rm`/`mv` call.
- "It's just a symlink, same file" / "quick tweak, I'll port it back later" / "the installer would overwrite it anyway".
- Using a tool's own installer (`/plugin install`, `opencode mcp add`, `skill-creator` output directory) that writes straight to the destination: run it, then move the result into the repo and re-run `install.sh`.

If the repo is unreachable or the change is machine-local, say so and ask; do not fall back to editing the destination.
