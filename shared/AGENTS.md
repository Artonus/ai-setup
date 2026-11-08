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

## Web content (Firecrawl)

When the Firecrawl tools are available, always use them to fetch website contents (scrape, crawl, map, search, extract) instead of the built-in web fetch or `curl`. Fall back to another method only if Firecrawl fails or is unavailable, and say so. Library documentation still goes through Context7 first (below).

## Library documentation (Context7)

When the Context7 tools are available, use them whenever the user asks about a library, framework, SDK, API, CLI tool, or cloud service, even well-known ones. This covers API syntax, configuration, version migration, library-specific debugging, setup, and CLI usage. Use them even when you think you know the answer: your training data may be out of date. Prefer them over web search for library docs.

Do not use them for refactoring, writing scripts from scratch, debugging business logic, code review, or general programming concepts.

1. Start with `resolve-library-id` using the library name and the user's question, unless the user gives an exact `/org/project` ID.
2. Pick the best match by exact name, description relevance, snippet count, source reputation (High or Medium preferred) and benchmark score. If results look wrong, try alternate names (`next.js`, not `nextjs`). Use a version-specific ID when the user mentions a version.
3. Call `query-docs` with that ID and the user's full question, not single words.
4. Answer from the fetched docs.

## Memory (Trilium)

When the Trilium tools are available, use them as persistent memory. The `Memory` note tree has `Global` (`La2EPRPZznwZ`) and `Projects` (`BAWuYX9Hbpcy`, one child note per repo, titled with the repo name). Every memory is one short note labelled `#memory`, plus `#scope=global` or `#scope=project`, `#project=<repo>` for project scope, and `#core` for critical facts.

- **Recall first.** At the start of a task, call `memory_search` (the `memory-search` MCP) with a short description of the task; it ranks memories by meaning, so it finds them even when worded differently or in another language. Then search `#memory` with exact keywords (ticket ids, file names) and `#project=<repo>` for the current repo. Read a hit in full before relying on it. Use what you find; do not ask the user for facts already stored. If `memory_search` is unavailable, fall back to keyword search.
- **Route by kind.** User preference or personal fact: Global with `#core`. Cross-project convention: Global. Project decision, bug root cause, gotcha: under `Projects/<repo>` (create the repo note if missing). Critical project fact: same, with `#core`.
- **Store after** learning a preference or workflow, making a design decision, fixing a bug (root cause plus fix), choosing tooling, or finding a gotcha. Keep each note concise: a clear title and a few lines.
- **Update, don't duplicate.** Search before storing, with `memory_search` too. If a memory exists but is outdated or wrong, edit that note; delete it only if it no longer applies.
- **Do not store** trivia, anything already stored, temporary debugging output, secrets or credentials.
- Ask before deleting a memory note.

## Notes (Trilium)

When the Trilium tools are available, the user's knowledge base is there too. Memory is facts for you; notes are knowledge the user will read later. Save notes proactively, without being asked, following the `trilium-notes` skill:

- **Save** research results or a technical explanation worth rereading, a non-obvious problem and its solution, a comparison or decision with its reasoning, a how-to or setup steps you worked out, and ideas that came up on the way.
- **Skip** trivia, code that already lives in a repo, and anything already noted (search first; update the existing note instead of duplicating it). Never store secrets.
- **Place** the note under the best-fitting existing parent by your best guess; do not ask. Then tell the user in one line what you saved and where.

## Actionable findings from research

When research, an investigation or an answer to a question turns up something actionable on our side (a bug, a gap or inconsistency in our code, API, contracts, OpenAPI or docs, a missing endpoint or validation, a decision we still owe, tech debt), do not leave it buried in the prose:

- End the answer with a clearly labelled **Actionable items** section. For each item give one line on what is wrong, the evidence (file path and line, or the observed behaviour), and a **proposed issue**: title, type (Task or Bug) and a one-to-two line description. Use the tracker described under "Task tracking" below.
- Propose only; never create an issue without the user's confirmation.
- Keep it to real findings. If nothing is actionable, do not add the section.

## Task tracking (Linear)

Personal and `ai-setup` work is tracked in Linear, through the Linear tools when they are available. The workspace has one team, `Aartuss` (key `AAR`); the project `Prywatne` holds private goals.

- Before creating an issue, search with `list_issues` for a match and update it instead of duplicating it.
- Create an issue only when the user asks or confirms. Put it in the `Prywatne` project unless the user names another one.
- Write descriptions for a person to read. Put long agent detail in a collapsible "Agent notes" section at the end.
- Do not use any other tracker here. A work overlay may add a `work-tracker` skill; when it is available and the task belongs to a work repo, follow that skill instead of this section.
