# ai-setup: shared Claude Code + OpenCode configuration

Date: 2026-10-02

## Goal

A single public git repo holding my Claude Code and OpenCode configuration, installable on
personal and work machines (macOS and Ubuntu). Work-specific config never enters this repo;
it lives in a separate private overlay that layers on top at install time.

## Non-goals

- Claude Code plugin marketplace packaging (possible later).
- Windows support.
- Managing anything outside Claude Code and OpenCode config.

## Constraints and assumptions

- Public repo: no tokens, API keys, internal URLs, or company-specific rules.
- Targets: macOS and Ubuntu. `install.sh` is bash, avoids GNU-only flags (macOS ships BSD
  `readlink`/`sed` and an old bash). `jq` is the one required dependency (for JSON merge).
- Both tools should share one source of truth for rules, skills, agents, and commands where
  their formats allow it. Tool-specific config (`settings.json`, `opencode.json`) stays separate.
- Open: whether employer policy allows the overlay to live on work infrastructure is the
  user's call; the repo only supports an overlay path, it does not dictate where it lives.

## Repo layout

```
ai-setup/
├── README.md
├── install.sh              # idempotent; --dry-run, --uninstall
├── shared/
│   ├── AGENTS.md           # global rules, written once
│   ├── skills/             # SKILL.md folders readable by both tools
│   ├── agents/             # subagent definitions
│   └── commands/           # slash commands / prompts
├── claude/
│   ├── CLAUDE.md           # `@AGENTS.md` plus Claude-only notes
│   └── settings.json       # permissions, hooks, env (no secrets)
├── opencode/
│   └── opencode.json       # providers, MCP servers, permissions
├── overlay.example/        # template for the private work overlay
├── tests/                  # install.sh tests
└── docs/superpowers/specs/
```

## Install behaviour

- Targets: `~/.claude/` (CLAUDE.md, settings.json, skills/, agents/, commands/) and
  `~/.config/opencode/` (AGENTS.md, opencode.json, plus OpenCode's equivalents of
  skills/agents/commands; the script maps directory names where they differ).
- Files in `shared/` are symlinked into both tools, so one edit is seen by both.
- Overlay: if `$AI_SETUP_OVERLAY` points to an existing directory, its contents are applied on
  top of the base. Same-named files replace base files. `settings.json` and `opencode.json`
  are merged with `jq` into a locally generated file instead of being replaced.
- Safety: existing real (non-symlink) files are backed up before linking; `--dry-run` prints
  planned changes; `--uninstall` removes only links/files this script created.
- The overlay path is never recorded in the repo.

## Keeping the public repo clean

- Secrets come from environment variables (`{env:VAR}` in OpenCode, `${VAR}` in MCP
  definitions for Claude Code).
- `.gitignore`: `overlay/`, `*.local.*`, `settings.local.json`.
- Optional pre-commit secret scan (e.g. gitleaks).

## Testing

A shell test (bats or plain bash) runs `install.sh` against a temporary `$HOME` and asserts:

1. Symlinks point to the right sources.
2. Overlay files win over base files; JSON configs are merged.
3. A second run changes nothing (idempotent).
4. Existing real files are backed up.
5. `--uninstall` leaves no stray links.
6. `--dry-run` changes nothing on disk.

## Open items

- Seed content: the repo starts with minimal `AGENTS.md` and config; importing existing
  `~/.claude` / OpenCode config is a follow-up the user can request.
- Design inspiration from jabbas/opencode-config was offered but declined for now.
