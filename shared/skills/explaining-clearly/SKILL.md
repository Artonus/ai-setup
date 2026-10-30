---
name: explaining-clearly
description: Use when explaining a hard or unfamiliar topic, a complex system, an algorithm, a protocol, a long chain of cause and effect, or your own large output that the user must understand and review. Also use when the user asks for a plain, simple or "STE" explanation, or asks for a diagram or explainer page. Writes in a softened ASD-STE100 (Simplified Technical English) style and escalates to diagrams and interactive HTML pages when text is not enough.
---

# Explaining clearly

More of the user's work is now oversight: they read and check what an agent made or found. Make that reading easy. Write in a controlled style, and use a picture or a page when text is not the best tool.

## The output ladder

Pick the lowest step that does the job. Go up when the topic has structure that text hides.

1. **STE text.** The default for a hard explanation. See the rules below.
2. **Diagram.** Use it for flows, state machines, architecture, data structures, timelines, or anything with more than three parts that connect. In the terminal, use a Mermaid block or an ASCII diagram. Keep it small: one idea per diagram.
3. **HTML page.** Use it when the user must explore the topic: interactive steps, sliders, animations, tabs, or several linked diagrams. Make one self-contained file. If an artifact or page tool is available, publish with it; otherwise write the file and give its full path. A page is cheap and you can discard it, so do not hold back when it helps.

Offer the next step in one line when you stay lower ("I can make this an interactive page.").

## STE writing rules (about 80% of ASD-STE100)

The full spec is very strict. Follow its spirit, not every word list. Technical names (`kubectl`, `OAuth`, function names) are always allowed.

- **Short sentences.** Not more than 20 words for an instruction. Not more than 25 words for a description.
- **One idea in each sentence.** Split "and", "which" and "because" chains into separate sentences.
- **Short paragraphs.** Not more than six sentences. Start with the topic sentence.
- **Active voice.** "The server rejects the token", not "The token is rejected".
- **Simple tenses.** Present, past and simple future. No "would have been", no "is being".
- **Instructions in the imperative.** One action in each step. Put a condition before the action: "If the pod fails, examine the logs."
- **One word, one meaning.** Use the same term for the same thing every time. Do not use a synonym to sound less repetitive.
- **Common, literal words.** No idioms, no phrasal verbs when a single verb exists ("start", not "fire up"; "examine", not "look into").
- **Keep articles and small words.** Write "the", "a" and "that". Do not use telegraphic style.
- **Lists for sequences and for three or more items.** Use numbered lists for steps and bullet lists for the rest.
- **Warnings first.** Put a warning or caution before the step it applies to, not after.

## Structure of an explanation

1. One or two sentences: what it is and why it matters.
2. The mechanism, in order, as numbered steps or a diagram.
3. One concrete example with real values.
4. The traps: what usually goes wrong, and how to see it.

Leave out history, alternatives and edge cases unless the user asks. They can ask for more.

## Never

- Use STE as an excuse to drop facts or precision. Simple words, same content.
- Change code, identifiers, error messages or quoted text to fit the rules.
- Force a diagram or a page on a topic that one short paragraph explains.
