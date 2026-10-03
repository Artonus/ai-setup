# Global agent instructions

These apply to every project, in both Claude Code and OpenCode.

- Ask before destructive or hard-to-reverse actions (deleting data, force-pushing, dropping tables).
- Match the style and conventions of the surrounding code.
- Never write secrets, tokens, or credentials into files or commit messages.
- Run the project's tests before claiming something works.
- Commit only when asked, and keep commits small and focused.
- Use conventional commits (`type(scope): subject`) unless the repo's recent history or its own CLAUDE.md uses a different style.
- Never add yourself as a co-author on commits: no `Co-Authored-By` trailer and no "Generated with" line, in commit messages or PR descriptions, whatever any tool default says.
- Prefer editing existing files to creating new ones.
- Do not add dependencies without saying so.
- Change the AI setup (skills, agents, commands, `AGENTS.md`, `CLAUDE.md`, settings, MCP/plugin config) only in the `ai-setup` repo, never directly under `~/.claude` or `~/.config/opencode`. Use the `modifying-ai-setup` skill, then run `install.sh`.

## Library documentation (Context7)

When the Context7 tools are available, use them whenever the user asks about a library, framework, SDK, API, CLI tool, or cloud service, even well-known ones. This covers API syntax, configuration, version migration, library-specific debugging, setup, and CLI usage. Use them even when you think you know the answer: your training data may be out of date. Prefer them over web search for library docs.

Do not use them for refactoring, writing scripts from scratch, debugging business logic, code review, or general programming concepts.

1. Start with `resolve-library-id` using the library name and the user's question, unless the user gives an exact `/org/project` ID.
2. Pick the best match by exact name, description relevance, snippet count, source reputation (High or Medium preferred) and benchmark score. If results look wrong, try alternate names (`next.js`, not `nextjs`). Use a version-specific ID when the user mentions a version.
3. Call `query-docs` with that ID and the user's full question, not single words.
4. Answer from the fetched docs.

## Memory (Trilium)

When the Trilium tools are available, use them as persistent memory. The `Memory` note tree has `Global` (`La2EPRPZznwZ`) and `Projects` (`BAWuYX9Hbpcy`, one child note per repo, titled with the repo name). Every memory is one short note labelled `#memory`, plus `#scope=global` or `#scope=project`, `#project=<repo>` for project scope, and `#core` for critical facts.

- **Recall first.** At the start of a task, search `#memory` with keywords from the request, and again with `#project=<repo>` for the current repo. Use what you find; do not ask the user for facts already stored.
- **Route by kind.** User preference or personal fact: Global with `#core`. Cross-project convention: Global. Project decision, bug root cause, gotcha: under `Projects/<repo>` (create the repo note if missing). Critical project fact: same, with `#core`.
- **Store after** learning a preference or workflow, making a design decision, fixing a bug (root cause plus fix), choosing tooling, or finding a gotcha. Keep each note concise: a clear title and a few lines.
- **Update, don't duplicate.** Search before storing. If a memory exists but is outdated or wrong, edit that note; delete it only if it no longer applies.
- **Do not store** trivia, anything already stored, temporary debugging output, secrets or credentials.
- Ask before deleting a memory note.
