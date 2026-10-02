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

## Library documentation (Context7)

When the Context7 tools are available, use them whenever the user asks about a library, framework, SDK, API, CLI tool, or cloud service, even well-known ones. This covers API syntax, configuration, version migration, library-specific debugging, setup, and CLI usage. Use them even when you think you know the answer: your training data may be out of date. Prefer them over web search for library docs.

Do not use them for refactoring, writing scripts from scratch, debugging business logic, code review, or general programming concepts.

1. Start with `resolve-library-id` using the library name and the user's question, unless the user gives an exact `/org/project` ID.
2. Pick the best match by exact name, description relevance, snippet count, source reputation (High or Medium preferred) and benchmark score. If results look wrong, try alternate names (`next.js`, not `nextjs`). Use a version-specific ID when the user mentions a version.
3. Call `query-docs` with that ID and the user's full question, not single words.
4. Answer from the fetched docs.
