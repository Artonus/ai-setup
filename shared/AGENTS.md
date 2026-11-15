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
- When implementing a job or plan, run independent tasks in parallel (several tool calls in one turn, or parallel subagents) instead of one after another. Run tasks in sequence only when one depends on another's output or when they touch the same files.
- Change the AI setup (skills, agents, commands, `AGENTS.md`, `CLAUDE.md`, settings, MCP/plugin config) only in the `ai-setup` repo, never directly under `~/.claude` or `~/.config/opencode`. Use the `modifying-ai-setup` skill, then run `install.sh`.
- Destructive commands (database clients, cluster and cloud mutations, force-push, deletes) are gated by `agent-guard`; state the target in one line in chat before running one.

## Web content (Firecrawl)

When the Firecrawl tools are available, always use them to fetch website contents (scrape, crawl, map, search, extract) instead of the built-in web fetch or `curl`. Fall back to another method only if Firecrawl fails or is unavailable, and say so. Library documentation still goes through Context7 first (below).

## Library documentation (Context7)

When the Context7 tools are available, use them whenever the user asks about a library, framework, SDK, API, CLI tool, or cloud service, even well-known ones. This covers API syntax, configuration, version migration, library-specific debugging, setup, and CLI usage. Use them even when you think you know the answer: your training data may be out of date. Prefer them over web search for library docs.

Do not use them for refactoring, writing scripts from scratch, debugging business logic, code review, or general programming concepts.

1. Start with `resolve-library-id` using the library name and the user's question, unless the user gives an exact `/org/project` ID.
2. Pick the best match by exact name, description relevance, snippet count, source reputation (High or Medium preferred) and benchmark score. If results look wrong, try alternate names (`next.js`, not `nextjs`). Use a version-specific ID when the user mentions a version.
3. Call `query-docs` with that ID and the user's full question, not single words.
4. Answer from the fetched docs.

## Memory (agent-memory)

When the `agent-memory` tools are available (a Graphiti knowledge graph; tools `search_memory_facts`, `search_nodes`, `add_memory`, `get_episodes`, `delete_episode`), use them as persistent memory. Facts are stored per `group_id`: `personal` is the default; a work overlay sets `work`. Always pass the same `group_id` when writing and reading.

- **Recall first.** At the start of a task, call `search_memory_facts` with a short description of the task and `group_ids`. Add `search_nodes` for a named service, person or ticket. Use what you find; do not ask the user for facts already stored. Facts the server has marked invalid are outdated; do not rely on them.
- **Store after** a decision, a state change ("X now owns Y"), a bug root cause with its fix, a tooling choice, a gotcha, or a stated preference. One `add_memory` call per atomic, dated statement written as a plain sentence naming its subject ("As of 2026-11-15 the billing-service retry job is owned by team Beta."). Give `name` a short title and pass `group_id`.
- **Change, don't pile up.** When a fact changes, add the new one as a new episode; the server invalidates the contradicted fact and keeps its history. Use `delete_episode` only for a wrong or unwanted episode, and ask the user first.
- **Cost.** Every episode runs several LLM calls. Batch related facts into one episode and skip trivia, anything already stored, temporary debugging output, secrets and credentials.
- **Unavailable.** If the tools are missing or a call fails, carry on without memory, say so in one line and do not retry in a loop.

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
