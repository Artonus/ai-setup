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
