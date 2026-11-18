---
name: herdr-session-supervisor
description: Use when the user asks to coordinate multiple agent sessions in Herdr, supervise a sequence of tickets through full-TUI workers, resume those workers after a restart, or handle idle orchestrators whose background agents are still running. Not for ordinary single-session coding or permission to delegate unasked.
---

# Herdr session supervisor

**Lifecycle is not completion.** A terminal can be `done` while its orchestrator's
children are still writing. Reconcile the live session, durable run, and Git evidence.

## 1. Establish ownership

Load the `herdr` skill first. If unavailable, run `herdr --skill` and follow it.
Require `HERDR_ENV=1`; discover current CLI syntax from help. This skill uses the
inherited local Herdr server, not whichever machine is focused in somebody's TUI.

Record the user's task order, agent/model choice, worktree/pane preferences and
approval boundaries. Separately record permissions for planning, implementation,
commits, push and draft PRs. Routine-plan auto-approval does not authorise publishing,
merging, deployment or destructive actions. Use the project's development workflow.

Create a durable, Git-ignored supervisor checkpoint inside the repository, not in
temporary storage. Use [the checkpoint template](references/checkpoint.md).
Keep project-specific facts there, not in this reusable skill.

**Ready:** the checkpoint identifies existing workers and allowed next actions.

## 2. Dispatch once

Inspect existing agents/worktrees and tracker state before starting a ticket.
For sequential work, finish verification of the prerequisite before dispatching the
next task. Parallelise independent slices only when they have disjoint file ownership;
each app's coordinator owns integration and the gate. Serialise memory-heavy tests.

Use the authorised worktree and a new sibling pane when requested; preserve focus.
Dependent branches can stack on reviewed prerequisite commits, with draft PRs targeting
that prerequisite branch. Unmerged drafts need not be merged to advance.

Start the requested **full TUI** with an explicit session and agent. With OpenCode,
discover session-creation syntax from the installed API/tools; do not guess endpoints.
Inspect the visible agent/model before submitting work. If it differs from the request,
stop; do not substitute Mini, a cheaper model or another agent silently.

A dispatch contains: one task/phase, checkpoint and artifact paths, base commit,
owned files, acceptance/gate, approval boundary and stop conditions. Reference settled
decisions instead of repeatedly copying the whole history. Record the returned pane,
agent name and `agent_session.value` before dispatch; update tracker only as authorised.

**Dispatched:** one verified session owns the task; its prompt was submitted once.

## 3. Wait on lifecycle events

After dispatch, inspect the durable run and live state once. Use the bundled waiter
through the harness's background-command facility and await its completion notification:

```bash
python3 <skill-dir>/scripts/wait_for_run.py \
  --agent feature-worker \
  --expected-session <verified-agent-session-value> \
  --run-file <absolute-worktree-path>/.superpowers/dev-flow/feature.run.md \
  --timeout-seconds 1800
```

Requirements: Python 3.10+, Herdr on PATH, local readable run file with exactly one
`status: in_progress|passed|stopped` line. Adapt the workflow explicitly if it uses
other statuses. The script only invokes `agent get`/`wait`; it never prompts, writes
the run file or advances tasks. Run one waiter per supervised task.

| Exit / outcome | Supervisor action |
|---|---|
| `0 / passed` | Verify gate, review, Git and publication evidence; not proof by itself. |
| `3 / stopped` | Read the escalation; report the actual blocker. |
| `2 / inspection_required` | Inspect once. Reconcile before choosing a new action. |

The waiter checks identity and existing terminal state first. Working agents are
awaited until settled; settled non-terminal runs are awaited until new work or a
block. Every wake-up gets a fresh snapshot. `blocked`, `unknown`, changed session,
bad run data, CLI failure and event exhaustion require inspection.

**Limit:** Herdr's get/wait interface has no revision cursor. A whole turn can finish
between calls; this is not a lossless event subscription. The bounded timeout performs
one final reconciliation (up to five extra seconds), then exits. The time bound
assumes a responsive local filesystem; it cannot bound an OS-stalled file read.
Do not replace this
with sleeps, repeated screen/file reads or automatic timeout retries.

## 4. Recover, verify, advance

After restart/timeout, read the checkpoint, `agent get`, visible output, run file and
Git state. A timeout is neither cancellation nor permission to resend the prompt.
If children are active, keep the original run. If session identity changed or unrelated
work is visible, leave that pane untouched and reconcile ownership with the user.

At the project's context limit, checkpoint completed/pending slices and verified
commands. Replace only the owned, settled task session; verify the fresh TUI/model
and record the new session identity before resuming pending work. Retire its old waiter.

Before advancing, require the agreed full gate and independent review, inspect the
actual diff and rerun focused verification. Run-status/Git discrepancies need
reconciliation, not a success edit to the run file. Preserve unknown user changes.
If publication was authorised, verify the remote head, PR base, draft flag and clean
task-only tree. Keep tracker status according to the user's policy, not an assumed Done.

Checkpoint the evidence and next task. Report only meaningful progress or blockers;
do not present dispatch completion as feature completion.

## Share and test

Share this **whole directory**, including `scripts/`, `references/`, `tests/` and
`evals/`. Put it in the colleague's configured skill source directory; load
`herdr-session-supervisor`. No Python packages, account credentials or project data
are bundled. Run `python3 <skill-dir>/tests/test_wait_for_run.py` for script tests.
The `evals/` cases exercise the human-facing supervision decisions without live control.
