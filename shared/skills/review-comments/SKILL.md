---
name: review-comments
description: Writes code-review comments in Bartosz Bratus's direct, conversational review style and proposes the review outcome (neutral, approve, request changes). Use when turning review findings into inline comments, drafting PR feedback, posting an approved review, or refining a review comment for any hosting platform.
---

# Review Comments

Write comments for the person changing the code, not a review report. This
skill covers wording only; use the relevant review workflow to establish that a
defect is real before calling it one.

## Human Approval Gate

Generate comments as a proposed review only. Present every comment, its target
file and line when applicable, and its severity or tag for Bartosz to review.
Always end the proposal with the suggested review outcome (see Review Outcome).
Wait for explicit approval before submitting any comment, review batch,
approval, or review verdict to Bitbucket or GitHub.

Approval applies only to the comments and the outcome explicitly approved in
the current review. If any comment or the outcome changes after approval,
present the change and wait for approval again. Never infer approval from a
request to generate, review, refine, or prepare comments.

## Posting An Approved Review

Once Bartosz approves, post the review directly with the approved outcome. Never
leave it as a pending or draft review: a pending review is invisible to the
author and defeats the approval step.

- **GitHub:** create one review with all approved inline comments and an explicit
  `event`: `COMMENT`, `APPROVE`, or `REQUEST_CHANGES`. Omitting `event` creates a
  pending review, so never omit it. Anchor comments to the PR head commit and to
  lines that are part of the diff. On GitHub Enterprise pass `--hostname <host>`
  to `gh api`; without it `gh api` targets github.com and returns 404.
- **Bitbucket:** inline comments are posted immediately; then set the participant
  status to match the outcome (Approve, Needs work) or leave it unchanged for the
  neutral outcome.
- If Bartosz approves only some comments, post only those and say which were
  skipped. After posting, report the review link and the submitted outcome.

## Review Outcome

Propose exactly one outcome with a one-line reason, based on the most severe
finding in the proposed comments.

| Outcome | GitHub / Bitbucket | Use when |
|---|---|---|
| Neutral | Comment / comments only, status unchanged | There are some errors or suggestions worth fixing, but nothing too serious; the comments are the point and the author can reasonably merge after addressing them. |
| Approve | Approve / Approve | Everything is good and the only comments are `[Nitpick]` or `[OPTIONAL]`. |
| Request changes | Request changes / Needs work | Any hard bug, spec drift (the code does not match the issue or design), or an optimisation problem that matters. |

- One blocking finding is enough for Request changes, however many nitpicks
  surround it.
- Untagged confirmed defects count by their real impact: a cosmetic copy error
  is Neutral, a failure path in normal use is Request changes.
- `[Suggestion]` items alone are Neutral, not Approve, unless Bartosz marks them
  optional.
- When a finding sits between two outcomes, propose the more severe one only if
  merging as-is would leave the PR wrong or unsafe; otherwise propose the lighter
  one and name the borderline finding in the reason.
- Format the proposal's last line as: `Suggested outcome: <Neutral | Approve |
  Request changes> — <reason>`.

## Voice

- Be direct and conversational. Use ordinary technical English, codebase names,
  and a little first-person judgement when it makes the feedback clearer.
- Natural openings include: "Maybe we should...", "Do we really need...", "I
  think...", "Personally, I am not a fan of...", and, for a substantial
  concern, "To be frank...".
- Prefer a focused question for a design choice or uncertain scope. Do not turn
  a preference into a definite bug.
- For a confirmed defect, name the concrete failure path before proposing the
  smallest useful fix.
- Keep one independently actionable concern per comment. Use short comments by
  default; spend more words only when explaining a meaningful reliability or
  architectural risk.
- Use slightly informal but precise phrasing when appropriate: "whole client",
  "keep the constructor slim", or "it will just crash". Do not flatten the
  comment into impersonal review-report language.
- Keep technical feedback separate from social PR conversation. Friendly banter
  belongs in a reply to banter, not in an actionable code-review comment.

## Comment Modes

Choose the mode that matches the certainty and consequence of the finding.

### Confirmed defect

State current behaviour, the concrete condition that makes it fail, and the
fix direction. Keep it compact when the diff already supplies the context.

```md
When `paymentClient` throws during startup, this constructor prevents
the IoC container from being created and the whole service crashes. Initialize
only the metrics here; publish the initial values from a dedicated async method
after the app is built.
```

### Design question or suggestion

Lead with the question or preference. Explain the responsibility, readability,
or future-maintenance cost if that makes the requested direction less obvious.

```md
Do we really need to include the whole client? Maybe it will be better to keep
only the methods that will be used by the service to have clear responsibility
boundaries?
```

```md
[Suggestion]
Maybe we should clean up this class, as we're not using most of the error
messages?
```

### Longer architecture concern

Use a longer comment only when the code has a non-obvious failure path. State
the design concern, walk through what can fail and why, then show the intended
shape. A small code sketch is useful when it removes ambiguity.

```md
To be frank, I am not a fan of placing this type of actions in the constructor.
Especially any type of business logic that requires calling external services.
Constructor should be as slim as possible.

Moreover, placing this method here could result in the whole service crashing
when the client throws an exception, disrupting creation of the IoC container.
I would extract this to a dedicated async method and call it after the app is
built.
```

### Scope containment

When unrelated work appears in a focused PR, state that it is out of scope and
give a concrete reason when one is available. Point to the existing work rather
than reopening the design discussion in the wrong PR.

```md
I think that entire `ReportExportManager` can be disregarded in this
PR. It is out of scope of this task and I have already implemented it in my PR,
which addresses the agreed requirements.
```

### Evidence-first correction

When a proposed safeguard or change is already present, say so briefly and cite
the exact code that provides the guarantee. This closes the concern without
asking for redundant work.

```md
It is covered by: `builder.HasIndex(x => new {
x.OrderId, x.LineItemId }).IsUnique();`
```

## Tags And Suggestions

- Mark discretionary feedback explicitly: `[Nitpick]` for minor readability or
  formatting, `[Suggestion]` for a broader improvement, and `[OPTIONAL]` for an
  idea that is clearly outside the PR's necessary work.
- Do not tag confirmed correctness, security, reliability, or data-integrity
  issues. State those plainly.
- Use a Bitbucket suggestion block when the exact replacement is small and
  safe. The suggestion may stand on its own when the replacement is self-evident.
- Do not use an empty suggestion block to frame an observation. State the
  evidence directly unless there is an actual replacement to apply.

```md
[Nitpick]
I think it would be more readable when split into multiple lines :)
```suggestion
return !initialParametersResult.IsSuccess
    ? Content(initialParametersResult.ErrorMessage ?? string.Empty, ContentTypeXml)
    : Content(initialParametersResult.Content, ContentTypeXml);
```
```

```md
Unify the error messages to either always use "player" or "user" for
consistency.
```

## Match The Finding

| Finding | Useful comment pattern |
|---|---|
| Broken behavior | "When `<condition>`, `<current code>` causes `<result>`. `<fix direction>`." |
| Missing validation/error mapping | "When `<failure>` happens, `<current code>` returns `<result>`. Maybe return/use `<existing error or validation>` so the caller can handle it?" |
| Authorization | "A `<role>` with `<permission/state>` cannot `<action>` because `<guard/path>`. Gate/render it with `<correct permission>`." |
| Data integrity/concurrency | "When `<two operations/state>`, `<operation>` can `<bad result>`. Reuse `<existing lock/transaction/check>`." |
| Existing safeguard | "It is covered by: `<specific existing index, guard, transaction, or check>`." |
| Design boundary | "Do we really need `<broad dependency>`? Maybe it will be better to keep `<narrow dependency>` to have clear responsibility boundaries?" |
| Scope containment | "I think `<unrelated change>` can be disregarded in this PR. It is out of scope of this task and `<existing work/reason>`." |
| Readability | "[Nitpick]\nI think it would be more readable when `<small change>` :)" |
| Non-blocking idea | "[OPTIONAL]\nMaybe we should `<improvement>`?" |

## Precision Rules

- Keep confirmed defects and optional design feedback distinct.
- Keep unrelated changes out of a focused PR; identify the existing work that
  covers them where known.
- Tie a defect to a realistic input, lifecycle state, external failure, role, or
  concurrent operation.
- Do not repeat the entire diff or quote requirements unless that makes missing
  behaviour unambiguous.
- Do not use vague review boilerplate. Explain why a design is a problem, or
  ask the focused question.
- Do not use severity headings, checklists, or review-report summaries in
  inline comments.
- Use platform syntax only for an exact, safe inline suggestion. Do not give
  workflow instructions or links.

## Final Check

Before posting a confirmed defect, verify that the comment answers:

1. What does this code do now?
2. In what concrete situation does it cause a problem?
3. What change would resolve it?

For a design question or optional improvement, verify that the tag is accurate
and the question names the specific trade-off. If the fix is not clear, ask the
focused question instead of guessing.
