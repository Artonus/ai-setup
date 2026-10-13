---
name: meeting-notes
description: Turns meeting transcripts into Trilium meeting notes with a summary, topics, decisions and action items, carries over open items from the previous meeting, and proposes the user's own action items as Todoist tasks. Use when the user asks to process, summarise or take notes from a meeting transcript or recording, or to process new transcripts.
---

You turn raw meeting transcripts into meeting notes in the user's Trilium knowledge base, reached through the `trilium` MCP tools.

## Find the transcripts

- If the user names a file or folder, use that.
- Otherwise scan `~/transcriptions` and `~/notes` for `meeting-*.txt`. Filenames look like `meeting-YYYY-MM-DD-HHMM.txt`; take the meeting date and time from them.
- Skip a transcript that is already processed: search Trilium for `#transcript="<filename>"`. If a note exists, report it and move on.
- Never modify, move or delete a transcript file.
- If nothing new is found, say so and stop.

## Read the transcript

Transcripts are raw speech-to-text output with some noise. They come in two shapes:

- **Labelled** (recorded calls): lines like `[12:34] Me: …` and `[12:40] Remote: …`. `Me` is the user (their microphone); `Remote` is everyone else on the call, not one person. So "I'll do it" on a `Me` line makes the user the owner, and a commitment on a `Remote` line belongs to someone on the other side.
- **Unlabelled** (older or in-room recordings): plain text, no speakers, no timestamps.

- Ignore filler (greetings, "hej", small talk) and lines that are obvious speech-to-text artefacts, such as "Dziękuję za oglądanie!" or "Thanks for watching!".
- Read misheard words from context when the meaning is clear. When it is not, keep the word and mark it *(unclear)*.
- Take other people's names only from what was said (including who `Remote` speakers address or are addressed as). Mark attendees and owners worked out from context as *(inferred)*. Never invent an owner, a deadline or a decision.

## Write the note

1. **Find the root.** Search for `#meetingNotesRoot`. If there is none, create a top-level text note `Meetings` and give it that label.
2. **Pick the project.** Work out which project the meeting is about from what was discussed, and match it to the existing child notes of `Meetings` (titles are project names). If none fits but the project is clear, create a child note for it, titled like its siblings. If the project is unclear, use the child `Other` (create it if missing). Do not ask; report the choice at the end.
3. **Create the note** under the project note, as a text note (Markdown content), titled `YYYY-MM-DD HH:MM <short meeting name>`, for example `2026-10-12 10:30 Daily`.
4. **Label it** `#meeting`, `#project=<project note title>` and `#transcript=<filename>`.

Write the note in the transcript's language, headings included. Use these sections, in this order, and leave out a section only when it would be empty:

- **Summary**: 3 to 6 sentences on what the meeting was for and what came out of it.
- **Attendees**: names mentioned as present.
- **Topics**: one bullet per topic, with a line or two on what was said.
- **Decisions**: what was agreed.
- **Action items**: a checklist; each item has an owner (or *unassigned*), a due date only if one was said, and a short context.
- **Open questions and risks**: what was raised but not resolved.
- **Carried over**: see below.

## Carry over open items

Read the most recent earlier note (by date in the title) in the same project folder. For each of its action items, decide from the new transcript whether it was finished. In the new note's **Carried over** section, list finished items struck through (`~~item~~`) and unfinished ones as open checklist items. Do not edit the earlier note. Skip this section for the first meeting in a project.

## Todoist: the user's own action items

1. Find out who the user is from Todoist's user info (name, and the short forms of it a colleague might say).
2. Pick the action items owned by the user, including carried-over open ones.
3. If you can ask the user (you are running as the main session), show the list and create only the tasks they confirm. Each task gets its due date if one was said, and a description with the meeting title and a link to the Trilium note. Do not create duplicates: search Todoist for the item first.
4. If you cannot ask the user (you are running as a subagent), do not create tasks. Return them as **Proposed Todoist tasks** in your report, ready to create.
5. If Todoist is not available, list the items in the report and say so.

## Report

Finish with a short report: for each transcript, the note title and where it was placed (and whether that project folder is new or `Other`), the number of action items, anything marked *(unclear)*, and the Todoist tasks created or proposed.

## Never

- Store secrets, tokens or credentials in a note.
- Delete, move or rename an existing note.
- Create a Todoist task the user has not confirmed.
