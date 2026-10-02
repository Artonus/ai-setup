# Claude Code content for ai-setup

Date: 2026-10-02

## Goal

Fill the empty baseline with the Claude Code configuration I actually use, so any machine
gets it from `./install.sh`. Content only: no installer changes.

## Non-goals

- OpenCode content (separate pass).
- The `notes` agent. It is tied to a personal note-taking setup that is changing. Left unmanaged in
  `~/.claude/agents/` until then.
- Work-specific settings (belong in the private overlay).
- A permissions model per project; this is the global baseline only.

## Captured from this machine

`~/.claude/settings.json` today: `model: sonnet`, `tui: fullscreen`, and three enabled
plugins from the built-in `claude-plugins-official` marketplace: superpowers,
frontend-design, context7. Plugins need no installer support: `enabledPlugins` is a normal
settings key.

## Design

### `claude/settings.json`

- `model: "sonnet"`, `tui: "fullscreen"`.
- `enabledPlugins`: `superpowers@claude-plugins-official`, `frontend-design@claude-plugins-official`,
  `context7@claude-plugins-official`, all `true`.
- `permissions.allow` (routine, reversible work):
  - Read-only: `git status`, `git diff`, `git log`, `git show`, `git branch --list`,
    `git branch --show-current`, `ls`, `gh pr view|list`, `gh run view`.
  - Local writes: `git add`, `git commit`, `git switch`, `git stash push|list`.
  - Tests/lint/build: `npm test`, `npm run test|lint|build`, `pnpm test|lint`, `pytest`,
    `ruff check`, `go test`, `cargo test|check`, `bash tests/run.sh`.
  - Deliberately absent: `cat`, `grep`, `rg` (Bash bypasses `Read` deny rules, and `rg --pre`
    runs programs; use the built-in Read/Grep tools), `git checkout`, bare `git stash` and
    bare `git branch` (can discard work or delete branches).
- `permissions.deny`: `Read(**/.env)`, `Read(**/.env.*)`, `Read(~/.ssh/**)`, `Read(~/.aws/**)`,
  `git push --force|-f`, `git reset --hard`, `rm -rf`, `sudo`, `git diff|log|show --output`,
  `git switch -f|--discard-changes`, common `rm -rf` spellings, `git push --force-with-lease`,
  `git commit -a|--amend|--no-verify`. Deny rules match one spelling by prefix, so they are
  best-effort; the prompt for anything not allowed is the real safeguard.
- Accepted risk: test, lint and build commands (`cargo`, `pytest`, `bash tests/run.sh`) run code
  from the repo, so opening an untrusted repo can execute its code without a prompt.
- Deliberately not allowed (still prompt): `git push`, `gh pr create`, dependency installs,
  anything else that reaches outside the machine.
- Overlay interaction: arrays are unioned on merge, so an overlay can add deny rules but
  never remove these.

### `shared/AGENTS.md`

Existing three rules stay. Add:

- Run the project's tests before claiming something works.
- Commit only when asked; keep commits small and focused.
- Use conventional commits (`type(scope): subject`) unless the repo's recent history or its
  own CLAUDE.md uses a different style.
- Prefer editing existing files to creating new ones.
- Do not add dependencies without saying so.

### `shared/commands/commit.md`

Frontmatter limited to fields both tools accept (`description`). Reads the staged diff and
writes a conventional commit message, following repo history if it differs. Commits only the
staged changes.

### Overriding the commit convention

An overlay `shared/AGENTS.md` replaces the base file wholesale, so it is not the lightweight
override path. The intended paths: a repo's own CLAUDE.md or history (handled by the rule's
"unless" clause), or an overlay `shared/commands/commit.md` for a machine-wide change.

## Testing

Extend `tests/test_layout.sh` (or add a case) to assert the installed `settings.json` is valid
JSON and contains the three plugins and the added deny rules, that `commit.md` is linked into
`~/.claude/commands/`, and that an overlay deny rule is unioned rather than replacing. Existing
install, idempotency and uninstall tests must still pass.

## Open items

None.
