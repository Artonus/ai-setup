# ai-setup

My shared Claude Code and OpenCode configuration. One repo, installed on personal and work
machines (macOS and Ubuntu). Work-specific config lives in a private overlay and never in
this repo.

## Layout

| Path | What it is |
|---|---|
| `shared/AGENTS.md` | Global rules, linked into both tools |
| `shared/skills/` | One folder per skill, linked into `~/.claude/skills` (OpenCode reads that too) |
| `shared/agents/`, `shared/commands/` | One file per agent / command, linked into both tools |
| `claude/` | `CLAUDE.md` (imports `AGENTS.md`) and `settings.json` |
| `opencode/` | `opencode.json` |
| `overlay.example/` | Template for a private work overlay |

## Install

Requires bash and, only when you use an overlay with JSON configs, `jq`.

```bash
./install.sh --dry-run   # see what would happen
./install.sh             # do it
./install.sh --uninstall # remove what it created (backups are kept)
```

Files already in the way are moved to `<name>.bak.<timestamp>`, never deleted. The installer
records what it created in `~/.local/state/ai-setup/manifest`, so re-running is a no-op,
links for entries you deleted from the repo are pruned, and `--uninstall` touches nothing else.

## Work overlay

Keep work config in a separate private directory or repo with the same layout
(see `overlay.example/`) and point the installer at it:

```bash
export AI_SETUP_OVERLAY=~/work/ai-setup-private   # e.g. in your work machine's shell profile
./install.sh
```

- Same-named files replace the base file. Note this means an overlay `shared/AGENTS.md`
  replaces the base one rather than adding to it.
- New entries in `shared/skills|agents|commands/` are added next to the base ones.
- `claude/settings.json` and `opencode/opencode.json` are deep-merged into a generated file:
  objects merge, arrays are unioned (an overlay can add `deny` rules but never drop base ones),
  overlay scalars win.
- A wrong `AI_SETUP_OVERLAY` path or invalid overlay JSON stops the install before anything changes.

## Keeping the public repo clean

- No tokens, keys, or internal URLs. Use `{env:VAR}` (OpenCode) or `${VAR}` (Claude Code MCP).
- `.gitignore` already excludes `overlay/`, `*.local.*`, and `settings.local.json`.
- Optional: run [gitleaks](https://github.com/gitleaks/gitleaks) (`gitleaks detect`) before pushing.

## Adding things

- A skill: `shared/skills/<name>/SKILL.md`, then `./install.sh`.
- A command or agent: drop a markdown file in `shared/commands/` or `shared/agents/`.
  Frontmatter fields differ between the tools; keep shared files to fields both accept.

## Tests

```bash
bash tests/run.sh
```

Runs the installer against a throwaway `$HOME` with paths containing spaces. Needs `jq`.

## Notes

Checked against the official docs (2026-10-02):

- OpenCode's global config directory is `~/.config/opencode/`, with plural subdirectory
  names (`agents/`, `commands/`, `skills/`); singular names still work for compatibility.
- OpenCode also loads skills from `~/.claude/skills/`, so skills are linked only there to
  avoid duplicates.
- OpenCode falls back to `~/.claude/CLAUDE.md` only when `~/.config/opencode/AGENTS.md` is
  missing; the installer always provides `AGENTS.md`.
- Claude Code resolves `@~/.claude/AGENTS.md` imports from the home directory, which is why
  `claude/CLAUDE.md` uses that path rather than a relative one (it is installed as a symlink).
- In Claude Cowork desktop sessions, a symlinked `~/.claude/CLAUDE.md` is skipped by design.
  Regular Claude Code is unaffected.
