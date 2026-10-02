# Work overlay template

Copy this directory somewhere **outside this repo** (for example a private repo
at `~/work/ai-setup-private`), edit it, and point the installer at it:

    export AI_SETUP_OVERLAY=~/work/ai-setup-private
    ./install.sh

The overlay mirrors the base layout: `shared/`, `claude/`, `opencode/`.

- A file with the same name as a base file replaces it.
- New entries in `shared/skills|agents|commands/` are added next to the base ones;
  an entry with the same name replaces the base entry.
- `claude/settings.json` and `opencode/opencode.json` are deep-merged into the base:
  objects are merged, arrays are unioned, overlay scalars win.
- Never put secrets in the overlay either. Reference environment variables:
  `{env:VAR}` in OpenCode, `${VAR}` in Claude Code MCP definitions.
