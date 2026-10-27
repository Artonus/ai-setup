---
name: trilium-notes
description: Use when the user asks about their notes or knowledge base, wants to find something they wrote, or asks to create, update, organise or link notes, journal or daily entries, or atomic (Zettelkasten-style) notes. Also use proactively, without being asked, after research, a technical explanation, a non-obvious fix, a decision or comparison, or a worked-out how-to that is worth keeping. The notes live in Trilium, reached through the trilium MCP tools. Not for agent memory; that is the Memory section of AGENTS.md.
---

# Trilium notes

The user's personal knowledge base lives in Trilium, reached through the `trilium` MCP tools. It replaced an Obsidian vault: there are no markdown files on disk to read or grep.

## Scope

- **This skill:** the user's own notes: topic notes, journal and daily entries, atomic notes, project notes.
- **Not this skill:** agent memory (`#memory` notes under the `Memory` tree). Follow the Memory section of AGENTS.md for those, and never mix the two.

## Find your way first

The tree layout is not fixed here, so discover it instead of guessing:

1. Before creating anything, look at the top-level notes and the subtree you are about to write into. Reuse existing parents, titles and label names; do not invent a parallel structure.
2. To find a note, search by keywords from the request (full-text and title), then by label (`#label` or `#label=value`). Read a note in full before quoting or editing it.
3. For journal or daily entries, find the calendar root (the note with the `#calendarRoot` label) and use its year > month > day notes. If today's day note is missing, create it in that structure, titled like its siblings.

## Writing notes

- Put a new note under the existing parent that best fits its topic, by your best guess; do not ask. When two parents fit, pick the more specific one. When nothing fits, create a topic note under the closest top-level note, titled like its siblings.
- When saving proactively, do it without asking, then tell the user in one line what you saved and where, so they can move it.
- Atomic notes: one idea per note, a clear descriptive title (not an ID), a short explanation, and links to related notes.
- Link notes with Trilium internal links (reference links to the target note), not `[[wikilinks]]` or markdown links.
- Use labels (`#tag`, `#tag=value`) where Obsidian used YAML frontmatter tags, matching the label names already in use.
- Keep the user's own wording when editing; make targeted changes rather than rewriting a whole note.
- Plain language by default. The user is a software engineer, so technical terms are fine when needed, but prefer simple explanations over jargon.
- After creating a note, suggest existing notes it could link to or from.

## Never

- Delete, move or rename a note without the user confirming it first.
- Store secrets, tokens or credentials in a note.
- Fall back to `~/Notes` or other local files; the vault there is retired.
