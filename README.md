# ai-setup

My shared Claude Code and OpenCode configuration. One repo, installed on personal and work
machines (macOS and Ubuntu). Work-specific config lives in a private overlay and never in
this repo.

## Layout

| Path | What it is |
|---|---|
| `shared/AGENTS.md` | Global rules, linked into both tools |
| `shared/skills/` | One folder per skill, linked into `~/.claude/skills` (OpenCode reads that too) |
| `vendor/anthropic-skills/` | Git submodule of [anthropics/skills](https://github.com/anthropics/skills); each skill in it is linked into `~/.claude/skills` too (a same-named skill in `shared/skills/` wins) |
| `shared/agents/`, `shared/commands/` | One file per agent / command, linked into both tools |
| `claude/` | `CLAUDE.md` (imports `AGENTS.md`) and `settings.json` |
| `vendor/mattpocock-skills/` | Git submodule of [mattpocock/skills](https://github.com/mattpocock/skills); the `engineering/` and `productivity/` skills are linked into `~/.claude/skills` (same precedence as above; those superpowers already covers are skipped, see `MATT_SKIP` in `install.sh`) |
| `opencode/` | `opencode.json`, plus optional OpenCode-only `skills/`, `agents/`, `commands/` (linked only into `~/.config/opencode`; a same-named shared agent or command is replaced there) |
| `tools/bin/` | Helper scripts, linked into `~/bin` (put it on `PATH`); empty here, the overlay can add its own |
| `overlay.example/` | Template for a private work overlay |

## Install

```bash
git clone --recurse-submodules <repo-url>   # or, in an existing clone:
git submodule update --init
```

Requires bash and, only when you use an overlay with JSON configs, `jq`.

```bash
./install.sh --dry-run   # see what would happen
./install.sh             # do it
./install.sh --uninstall # remove what it created (backups are kept)
```

Files already in the way are moved to `<name>.bak.<timestamp>`, never deleted. The installer
records what it created in `~/.local/state/ai-setup/manifest`, so re-running is a no-op,
links for entries you deleted from the repo are pruned, and `--uninstall` touches nothing else.
Anything you changed since (a file put in place of one of our links, an edited generated config)
is no longer "ours": it is backed up on install and left alone by prune and uninstall.

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

## MCP servers (OpenCode)

`opencode/opencode.json` declares `context7` (key from `CONTEXT7_API_KEY`), `todoist` (OAuth in
the browser on first use), `trilium` (trilium.example.com, token from `TRILIUM_MCP_TOKEN`) and
`google-calendar`. Google Calendar ships **disabled**: it needs a
Google Cloud project with the Calendar API and Calendar MCP API enabled and a web OAuth client.
Export `GOOGLE_MCP_CLIENT_ID` and `GOOGLE_MCP_CLIENT_SECRET`, set
`mcp.servers.google-calendar.disabled` to `false` in your overlay's `opencode/opencode.json`,
then sign in with `opencode mcp auth google-calendar`.

## OpenCode plugins

`superpowers` is installed through OpenCode's plugin list and tracks the upstream `main`
branch (no version pin), so an upstream change reaches your sessions on the next OpenCode
start. To pin, append a tag: `...superpowers.git#v7.0.0` (V2 needs `v6.4.1` or later). Verify
by asking OpenCode: "Tell me about your superpowers".

Claude Code reads user-scope MCP servers from `~/.claude.json`, not `settings.json`, so
`install.sh` merges `claude/mcp.json` (and the overlay's copy) into that file's `mcpServers`.
Your other servers and Claude Code's own state are left alone; servers removed from the repo are
removed on the next run, and `--uninstall` takes ours back out. `trilium` reads its token from
`${TRILIUM_MCP_TOKEN}`, expanded by Claude Code at startup.

## Adding things

- A skill: `shared/skills/<name>/SKILL.md`, then `./install.sh`.
- A command or agent: drop a markdown file in `shared/commands/` or `shared/agents/`.
  Frontmatter fields differ between the tools; keep shared files to fields both accept.

Update the vendored skills with `git submodule update --remote vendor/anthropic-skills vendor/mattpocock-skills`, then commit
the new pointer and re-run `./install.sh` (it links new skills and prunes removed ones).

## Tests

```bash
bash tests/run.sh
```

Runs the installer against a throwaway `$HOME` with paths containing spaces. Needs `jq`.

## Notes

Checked against the official docs (2026-10-02; OpenCode V2 on 2026-10-16):

- `opencode/opencode.json` uses the OpenCode V2 shape: `mcp.servers.<name>` with `disabled`,
  snake_case OAuth fields, an ordered `permissions` array (last match wins) and `plugins`.
  `opencode debug config` shows how OpenCode reads the installed file.
- OpenCode's global config directory is `~/.config/opencode/`, with plural subdirectory
  names (`agents/`, `commands/`, `skills/`); singular names still work for compatibility.
- OpenCode also loads skills from `~/.claude/skills/`, so skills are linked only there to
  avoid duplicates.
- OpenCode V2 reads only `AGENTS.md`, never `CLAUDE.md`; the installer always provides
  `~/.config/opencode/AGENTS.md`, so Claude-only notes in `claude/CLAUDE.md` stay out of OpenCode.
- Claude Code resolves `@~/.claude/AGENTS.md` imports from the home directory, which is why
  `claude/CLAUDE.md` uses that path rather than a relative one (it is installed as a symlink).
- In Claude Cowork desktop sessions, a symlinked `~/.claude/CLAUDE.md` is skipped by design.
  Regular Claude Code is unaffected.
