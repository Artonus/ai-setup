# Supervisor checkpoint contract

Store this in a Git-ignored state directory inside the repository. Pick paths using
the project's conventions and verify ignore rules before writing. Keep secrets and
copied terminal transcripts out; record paths and concise evidence instead.

Update before dispatch, after a completed slice/review/publication, and before a
context handoff. Use one supervisor writer; workers own their own task run files.

```markdown
# Supervision: <initiative>
status: in_progress
updated: <date>

## Authority
- User request and task order:
- Requested agent/model/TUI:
- Planning/implementation/publication permissions (separate):
- Tracker/assignee/status policy:
- Actions that still require user approval:

## Active task
- Ticket / phase:
- Worktree / branch / base commit:
- Herdr server context / agent name / pane:
- agent_session.value (verified before dispatch):
- Design / feature / plan / task run paths:
- Last dispatched instruction (purpose, not full transcript):
- Completed slices and exact verification evidence:
- Active child slices and disjoint owned files:
- Pending work / actual blockers:
- Background waiter job ID and expected session:

## Reviewed prerequisites
- Task / commit / full gate / independent review:
- Draft PR URL / base / head / draft flag:

## Decisions
- Settled business/technical choices with source:
- External release gates (not invented answers):

## Recovery / next action
- What to inspect after restart:
- Existing work not to redispatch:
- Next authorised action and completion criterion:
```

The bundled waiter reads a **task run file**, not this whole ledger. Minimum format:

```markdown
# Run: <task>
status: in_progress
```

The task coordinator changes status to `passed` only after its workflow gate/review,
or `stopped` when escalation is needed. The supervisor independently verifies it.
`passed` need not mean publication completed; verify that separately.

## Recovery decisions

| Observation | Next action |
|---|---|
| `done` + `in_progress` + active children | Await their existing lifecycle; retain ownership. |
| `done` + `in_progress` + no known activity | Inspect output; reconcile with the verified coordinator, not a duplicate dispatch. |
| `working` + `passed` | Let the owned coordinator settle; it may still be publishing. |
| Same name, different session | Stop automatic control; a name can be reused. |
| Run says passed, Git/gate disagrees | Resolve evidence discrepancy before advancing. |
| Wait timeout | Inspect current state once; do not assume failure or repeat work. |
